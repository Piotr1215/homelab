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
argo-password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

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
  @NAME=$(echo "{{description}}" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(date +%Y%m%d-%H%M%S); \
  velero backup create "$NAME" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease \
    --wait
  @echo "Backup complete. Listing recent backups:"
  velero backup get | head -10


# Interactive Kubernetes upgrade - shows versions and lets you choose
k8s-upgrade:
  #!/usr/bin/env bash
  CURRENT=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  echo "Current version: $CURRENT"
  echo
  CURRENT_MINOR=$(echo "$CURRENT" | cut -d. -f2)
  NEXT_MINOR=$((CURRENT_MINOR + 1))
  echo "Available upgrades:"
  VERSIONS=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases | \
    jq -r '.[] | .tag_name' | grep -E "^v1\.${NEXT_MINOR}\.[0-9]+$" | sort -V | head -5)
  if [ -z "$VERSIONS" ]; then
    echo "Already at latest supported version"
    exit 0
  fi
  echo "$VERSIONS" | nl -w2 -s'. '
  echo
  read -p "Enter version number or 'q' to quit: " CHOICE
  [[ "$CHOICE" == "q" ]] && exit 0
  TARGET=$(echo "$VERSIONS" | sed -n "${CHOICE}p")
  echo "Upgrading to $TARGET"
  read -p "Continue? (y/n) " -n1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] && ./scripts/k8s-upgrade.sh "$TARGET"


# Unseal Vault after restarts
unseal-vault:
  @echo "Unsealing Vault..."
  kubectl exec -n vault vault-0 -- vault operator unseal $(VAULT_UNSEAL_KEY)

