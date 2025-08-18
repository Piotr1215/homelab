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

# Manual Velero backup with optional description
backup-velero description="manual-backup":
  @echo "Creating Velero backup: {{description}}-$(date +%Y%m%d-%H%M%S)"
  velero backup create "{{description}}-$(date +%Y%m%d-%H%M%S)" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease \
    --wait
  @echo "Backup complete. Listing recent backups:"
  velero backup get | head -10
