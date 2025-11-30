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
  version    = "9.1.5"

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

# Deploy ArgoCD root application
resource "null_resource" "deploy_argocd_app" {
  depends_on = [helm_release.argocd]

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
output "argocd_server_command" {
  value = "kubectl get svc -n argocd argocd-server -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}'"
  description = "Run this command to get the ArgoCD server URL"
}