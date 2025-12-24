#!/usr/bin/env bash
set -euo pipefail

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

: "${BITWARDEN_MACHINE_ACCOUNT_TOKEN:?ERROR: export BITWARDEN_MACHINE_ACCOUNT_TOKEN and run: just cluster-restore}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL_PLANE="decoder@192.168.178.87"

# Pre-flight checks
echo "==> Pre-flight checks"

echo -n "  [etcd backup] "
LATEST_BACKUP=$(ssh "$CONTROL_PLANE" 'ls -t /var/backups/etcd/etcd-snapshot-*.db 2>/dev/null | head -1' || true)
if [[ -z "$LATEST_BACKUP" ]]; then
  echo "FAIL - No backups found"
  exit 1
fi
BACKUP_AGE=$(ssh "$CONTROL_PLANE" "stat -c %Y '$LATEST_BACKUP'" 2>/dev/null)
HOURS_OLD=$(( ($(date +%s) - BACKUP_AGE) / 3600 ))
echo "OK ($(basename "$LATEST_BACKUP"), ${HOURS_OLD}h old)"

echo -n "  [bitwarden token] "
echo "OK (set)"

cat << 'EOF'

==> Step 1/5: Rebuild VMs if needed
If VMs don't exist, create them:
  just create-worker-vm pve2 name=kube-main vmid=101 cores=4 memory=16384
  just create-worker-vm pve2 name=kube-worker1 vmid=102
  (repeat for all nodes)
Then: just ansible-cluster (to provision cluster via Kubespray)

==> Step 2/5: Restore etcd on control plane (192.168.178.87)
  sudo systemctl stop etcd
  LATEST=$(ls -t /var/backups/etcd/etcd-snapshot-*.db | head -1)
  sudo etcdutl snapshot restore "$LATEST" --data-dir /var/lib/etcd
  sudo chown -R etcd:etcd /var/lib/etcd
  sudo systemctl start etcd
EOF

if [[ "$AUTO_MODE" == "false" ]]; then
  read -p "Press ENTER when done..."
else
  echo "[--auto mode] Skipping interactive prompt"
fi

kubectl get nodes >/dev/null || { echo "ERROR: Cluster not accessible"; exit 1; }

echo "==> Step 3/5: Bootstrap ArgoCD"
cd "${SCRIPT_DIR}/cluster-bootstrap" && terraform init >/dev/null && terraform apply -auto-approve
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s >/dev/null

echo "==> Step 4/5: Configure External Secrets"
cd "${SCRIPT_DIR}" && just patch-bitwarden

echo "==> Step 5/5: Sync all apps"
kubectl apply -f "${SCRIPT_DIR}/gitops/clusters/homelab/" >/dev/null
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s >/dev/null

# Post-restore verification
echo "==> Post-restore verification"
echo -n "  [nodes] "
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
echo "OK ($NODE_COUNT nodes)"

echo -n "  [argocd] "
kubectl get applications -n argocd --no-headers 2>/dev/null | head -3 | awk '{print $1}' | paste -sd, -
echo ""

echo "Done. ArgoCD: https://argocd.homelab.local"
