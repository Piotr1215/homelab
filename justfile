set export

copy := if os() == "linux" { "xsel --clipboard" } else { "pbcopy" }
browse := if os() == "linux" { "xdg-open" } else { "open" }

default:
  just --list

# SSH connections
ubuntu:
  ssh coder@${UBUNTU_HOST}

kube-main:
  ssh decoder@${KUBE_MAIN}

kube-worker1:
  ssh decoder@${KUBE_WORKER1}

kube-worker2:
  ssh decoder@${KUBE_WORKER2}

proxmox:
  ssh root@${PROXMOX_HOST}

# Utilities
get-kubeconfig:
  scp decoder@${KUBE_MAIN}:/etc/kubernetes/admin.conf ./kubeconfig

# Launch ArgoCD UI
launch_argo:
  #!/usr/bin/env bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | {{copy}}
  ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  nohup {{browse}} http://$ARGO_IP >/dev/null 2>&1 &

# Launch Homepage
launch_homepage:
  #!/usr/bin/env bash
  HOMEPAGE_IP=$(kubectl get svc -n homepage homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  nohup {{browse}} http://$HOMEPAGE_IP >/dev/null 2>&1 &

# Get ArgoCD password
argo_password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Login to ArgoCD CLI
argo_login:
  #!/usr/bin/env bash
  ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "y" | argocd login $ARGO_IP --username admin --password $ARGO_PASSWORD --insecure
  echo "✓ Logged in to ArgoCD at $ARGO_IP"

# Sync a specific ArgoCD application
argo_sync app="":
  #!/usr/bin/env bash
  if [ -z "{{app}}" ]; then
    echo "Usage: just argo_sync <app-name>"
    echo "Available apps:"
    argocd app list -o name
  else
    argocd app sync {{app}} --prune
  fi

# Sync all ArgoCD applications
argo_sync_all:
  #!/usr/bin/env bash
  for app in $(argocd app list -o name); do
    echo "Syncing $app..."
    argocd app sync $app --prune
  done

# Hard refresh ArgoCD app (with --hard-refresh flag)
argo_refresh app="":
  #!/usr/bin/env bash
  if [ -z "{{app}}" ]; then
    echo "Usage: just argo_refresh <app-name>"
    argocd app list -o name
  else
    argocd app get {{app}} --hard-refresh
  fi

# Get ArgoCD app details
argo_get app="":
  #!/usr/bin/env bash
  if [ -z "{{app}}" ]; then
    argocd app list
  else
    argocd app get {{app}}
  fi

# Show ArgoCD app manifest
argo_manifest app:
  argocd app manifests {{app}}

# Show diff between live and desired state
argo_diff app:
  argocd app diff {{app}}

# Delete an ArgoCD application

# Bootstrap ArgoCD for specific environment (bare-metal or managed)
bootstrap env="bare-metal":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "🚀 Bootstrapping ArgoCD for {{env}} environment..."
  
  # Validate environment
  if [[ "{{env}}" != "bare-metal" && "{{env}}" != "managed" ]]; then
    echo "❌ Invalid environment. Use: bare-metal or managed"
    exit 1
  fi
  
  # Install ArgoCD based on environment
  if [[ "{{env}}" == "bare-metal" ]]; then
    echo "📦 Installing ArgoCD with LoadBalancer for bare-metal..."
    cd terraform/argocd && terraform init && terraform apply -auto-approve
  else
    echo "📦 Installing ArgoCD with ClusterIP for managed K8s..."
    # Create namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    # Install with ClusterIP instead of LoadBalancer
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      --set server.service.type=ClusterIP \
      --set configs.params."server\.insecure"=true \
      --wait
  fi
  
  # Wait for ArgoCD to be ready
  echo "⏳ Waiting for ArgoCD to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
  
  # Apply environment-specific applications
  echo "📝 Applying {{env}} applications..."
  kubectl apply -f gitops/clusters/{{env}}/
  
  echo "✅ Bootstrap complete for {{env}}!"
  
  # Show access info
  if [[ "{{env}}" == "bare-metal" ]]; then
    ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    echo "🌐 ArgoCD URL: http://$ARGO_IP"
  else
    echo "🌐 ArgoCD access: kubectl port-forward -n argocd svc/argocd-server 8080:80"
  fi
  
  ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "🔑 Username: admin"
  echo "🔑 Password: $ARGO_PASSWORD"

# Initialize Vault after it's deployed by ArgoCD
init-vault nas_password="":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "🔐 Initializing Vault..."
  
  # Wait for Vault pod
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s || true
  
  # Port forward to Vault
  kubectl port-forward -n vault svc/vault 8200:8200 &
  PF_PID=$!
  sleep 3
  
  export VAULT_ADDR="http://127.0.0.1:8200"
  
  # Initialize Vault if needed
  if ! vault status 2>/dev/null | grep -q "Initialized.*true"; then
    echo "📝 Initializing Vault..."
    vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/vault-init.json
    UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
    ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault-init.json)
    
    echo "🔓 Unsealing Vault..."
    vault operator unseal "$UNSEAL_KEY"
    
    echo "⚠️  Vault credentials saved to /tmp/vault-init.json - SAVE THESE!"
    echo "Unseal key: $UNSEAL_KEY"
    echo "Root token: $ROOT_TOKEN"
  else
    echo "✓ Vault already initialized"
    # Try to unseal if sealed
    if [[ -f /tmp/vault-init.json ]]; then
      UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
      vault operator unseal "$UNSEAL_KEY" || true
    fi
  fi
  
  # Login to Vault
  ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault-init.json)
  export VAULT_TOKEN="$ROOT_TOKEN"
  
  # Enable KV v2 if needed
  vault secrets enable -path=secret kv-2 2>/dev/null || true
  
  # Add secrets
  echo "🔑 Adding secrets to Vault..."
  
  # NAS password (prompt if not provided)
  if [[ -z "{{nas_password}}" ]]; then
    read -s -p "Enter NAS password: " NAS_PWD
    echo
  else
    NAS_PWD="{{nas_password}}"
  fi
  
  # Store secrets in Vault
  vault kv put secret/synology/config password="$NAS_PWD"
  vault kv put secret/minio/config root_user="admin" root_password="$(openssl rand -base64 32)"
  vault kv put secret/homepage/config \
    argocd_token="$(openssl rand -base64 32)" \
    grafana_password="$(openssl rand -base64 32)" \
    portainer_key="$(openssl rand -base64 32)" \
    proxmox_password="changeme" \
    synology_password="$NAS_PWD"
  
  # Create ESO token
  ESO_TOKEN=$(vault token create -policy=default -format=json | jq -r '.auth.client_token')
  
  # Create vault-token secret in necessary namespaces
  for ns in default homepage velero minio external-secrets; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic vault-token \
      --from-literal=token="$ESO_TOKEN" \
      --namespace="$ns" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  
  kill $PF_PID 2>/dev/null || true
  echo "✅ Vault initialized and secrets added!"

# Delete an ArgoCD application
argo_delete app cascade="true":
  argocd app delete {{app}} --cascade={{cascade}}

# Rollback ArgoCD app to previous sync
argo_rollback app:
  argocd app rollback {{app}}

# Show ArgoCD app history
argo_history app:
  argocd app history {{app}}

# Terminate current sync operation
argo_terminate app:
  argocd app terminate-op {{app}}

# Wait for app to be healthy
argo_wait app timeout="600":
  argocd app wait {{app}} --health --timeout {{timeout}}

# Set app to manual sync
argo_manual app:
  argocd app set {{app}} --sync-policy none

# Set app to auto sync
argo_auto app:
  argocd app set {{app}} --sync-policy automated --auto-prune --self-heal

# Stop ArgoCD controller (kubectl method)
argo_stop:
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=0

# Start ArgoCD controller (kubectl method)
argo_start:
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=1

# Disable ArgoCD auto-sync for all apps (using ArgoCD CLI)
argo_suspend:
  #!/usr/bin/env bash
  for app in $(argocd app list -o name); do
    echo "Disabling auto-sync for $app..."
    argocd app set $app --sync-policy none
  done

# Enable ArgoCD auto-sync for all apps (using ArgoCD CLI)
argo_resume:
  #!/usr/bin/env bash
  for app in $(argocd app list -o name); do
    echo "Enabling auto-sync for $app..."
    argocd app set $app --sync-policy automated --auto-prune --self-heal
  done

# Check ArgoCD app status (detailed)
argo_status:
  argocd app list

# Show out-of-sync resources
argo_out_of_sync:
  argocd app list --out-of-sync

# Show apps with errors
argo_errors:
  argocd app list --health degraded,missing,unknown

# Create ArgoCD app from manifest in gitops/
argo_create app path:
  argocd app create {{app}} \
    --repo https://github.com/Piotr1215/homelab \
    --path {{path}} \
    --dest-server https://kubernetes.default.svc \
    --sync-policy automated \
    --auto-prune \
    --self-heal

# Check scanning jobs status
scan_status:
  @kubectl get cronjobs,jobs -n cluster-scanning

# Clean up completed scan jobs
scan_cleanup:
  @echo "Cleaning up completed scan jobs..."
  @kubectl delete jobs --field-selector status.successful=1 -n cluster-scanning 2>/dev/null || echo "No successful jobs to delete"
  @kubectl delete jobs --field-selector status.successful=1 -n cluster-scanning 2>/dev/null || echo "No failed jobs to delete"
  @kubectl delete jobs --field-selector status.successful=1 -n metallb-system 2>/dev/null || echo "No failed jobs to delete"
  @echo "Cleanup complete"

# Restart stuck kagent pods
restart-kagent:
    @echo "Restarting kagent pods..."
    kubectl rollout restart deployment k8s-agent -n kagent

# Manual Velero backup with optional description
backup-velero description="manual-backup":
  @echo "Creating Velero backup: {{description}}-$(date +%Y%m%d-%H%M%S)"
  velero backup create "{{description}}-$(date +%Y%m%d-%H%M%S)" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease \
    --wait
  @echo "Backup complete. Listing recent backups:"
  velero backup get | head -10

# Unseal Vault after restarts
unseal-vault:
  @echo "Unsealing Vault..."
  kubectl exec -n vault vault-0 -- vault operator unseal $(VAULT_UNSEAL_KEY)
