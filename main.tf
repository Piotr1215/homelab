terraform {
  required_version = ">= 1.0"
  
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Variables
variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "./kubeconfig"
}

variable "vault_snapshot_path" {
  description = "Path to Vault snapshot file to restore (optional)"
  type        = string
  default     = ""
}

variable "vault_credentials_path" {
  description = "Path to Vault credentials JSON from previous installation"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository for GitOps"
  type        = string
  default     = "https://github.com/decodersam/homelab"
}

# Providers
provider "helm" {
  kubernetes {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

# Create argocd namespace
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Install ArgoCD using Helm
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "7.7.12"

  values = [
    <<-EOT
    server:
      service:
        type: LoadBalancer
        loadBalancerIP: "192.168.178.90"
    EOT
  ]

  wait = true
}

# Create vault namespace
resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

# Install Vault using Helm with Raft storage
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = "0.28.1"

  values = [
    <<-EOT
    server:
      ha:
        enabled: true
        replicas: 1
        raft:
          enabled: true
          config: |
            ui = true
            
            listener "tcp" {
              tls_disable = 1
              address = "[::]:8200"
              cluster_address = "[::]:8201"
            }
            
            storage "raft" {
              path = "/vault/data"
            }
            
            service_registration "kubernetes" {}
      
      dataStorage:
        enabled: true
        size: 10Gi
        storageClass: local-path
      
      service:
        type: LoadBalancer
        loadBalancerIP: "192.168.178.92"
    
    ui:
      enabled: true
      serviceType: LoadBalancer
      loadBalancerIP: "192.168.178.92"
    EOT
  ]

  wait = true
}

# Wait for Vault pod to be ready
resource "null_resource" "wait_for_vault" {
  depends_on = [helm_release.vault]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Vault pod to be ready..."
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
    EOT
    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }
}

# Initialize or restore Vault
resource "null_resource" "vault_init_or_restore" {
  depends_on = [null_resource.wait_for_vault]

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      VAULT_POD="vault-0"
      NAMESPACE="vault"
      
      # Check if Vault is already initialized
      INIT_STATUS=$(kubectl exec -n $NAMESPACE $VAULT_POD -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")
      
      if [ "$INIT_STATUS" = "false" ]; then
        echo "Vault is not initialized. Initializing..."
        
        # Initialize Vault
        kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator init \
          -key-shares=1 \
          -key-threshold=1 \
          -format=json > vault-init.json
        
        echo "Vault initialized. Credentials saved to vault-init.json"
        
        # Extract tokens
        export VAULT_UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
        export VAULT_TOKEN=$(jq -r '.root_token' vault-init.json)
        
        # Unseal Vault
        echo "Unsealing Vault..."
        kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal $VAULT_UNSEAL_KEY
        
        # If we have a snapshot to restore
        if [ -n "${var.vault_snapshot_path}" ] && [ -f "${var.vault_snapshot_path}" ]; then
          echo "Restoring Vault from snapshot: ${var.vault_snapshot_path}"
          
          # Copy snapshot to pod
          kubectl cp "${var.vault_snapshot_path}" $NAMESPACE/$VAULT_POD:/tmp/restore.snap
          
          # Restore snapshot
          kubectl exec -n $NAMESPACE $VAULT_POD -- sh -c "
            export VAULT_TOKEN='$VAULT_TOKEN'
            vault operator raft snapshot restore /tmp/restore.snap
          "
          
          echo "Vault snapshot restored successfully"
        fi
        
      elif [ -n "${var.vault_credentials_path}" ] && [ -f "${var.vault_credentials_path}" ]; then
        echo "Vault already initialized. Using existing credentials..."
        
        # Load existing credentials
        export VAULT_UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${var.vault_credentials_path}")
        export VAULT_TOKEN=$(jq -r '.root_token' "${var.vault_credentials_path}")
        
        # Check if sealed and unseal if needed
        SEALED=$(kubectl exec -n $NAMESPACE $VAULT_POD -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
        if [ "$SEALED" = "true" ]; then
          echo "Vault is sealed. Unsealing..."
          kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal $VAULT_UNSEAL_KEY
        fi
        
        # If we have a snapshot to restore
        if [ -n "${var.vault_snapshot_path}" ] && [ -f "${var.vault_snapshot_path}" ]; then
          echo "Restoring Vault from snapshot: ${var.vault_snapshot_path}"
          
          # Copy snapshot to pod
          kubectl cp "${var.vault_snapshot_path}" $NAMESPACE/$VAULT_POD:/tmp/restore.snap
          
          # Restore snapshot
          kubectl exec -n $NAMESPACE $VAULT_POD -- sh -c "
            export VAULT_TOKEN='$VAULT_TOKEN'
            vault operator raft snapshot restore -force /tmp/restore.snap
          "
          
          echo "Vault snapshot restored successfully"
        fi
      else
        echo "Vault is already initialized and no credentials provided"
      fi
      
      # Create or update root token secret for backup jobs
      if [ -n "$VAULT_TOKEN" ]; then
        kubectl create secret generic vault-root-token \
          --from-literal=token="$VAULT_TOKEN" \
          -n $NAMESPACE \
          --dry-run=client -o yaml | kubectl apply -f -
      fi
    EOT
  }
}

# Deploy ArgoCD root application
resource "null_resource" "deploy_argocd_app" {
  depends_on = [helm_release.argocd, null_resource.vault_init_or_restore]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for ArgoCD CRDs to be ready..."
      sleep 15
      kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s || true
      
      echo "Creating ArgoCD root application..."
      cat <<'EOF' | kubectl apply -f -
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: root
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: ${var.github_repo}
          targetRevision: HEAD
          path: gitops/
        destination:
          server: https://kubernetes.default.svc
          namespace: argocd
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
      EOF
    EOT
    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }
}

# Output important values
output "argocd_server" {
  value = "http://192.168.178.90"
}

output "vault_ui" {
  value = "http://192.168.178.92:8200"
}

output "vault_init_status" {
  value = "Check vault-init.json for credentials if freshly initialized"
}