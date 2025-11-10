#!/usr/bin/env bash
set -euo pipefail

: "${BITWARDEN_MACHINE_ACCOUNT_TOKEN:?ERROR: export BITWARDEN_MACHINE_ACCOUNT_TOKEN and run: just cluster-restore}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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
  sudo chown -R root:root /var/lib/etcd
  sudo systemctl start etcd
EOF
read -p "Press ENTER when done..."
kubectl get nodes >/dev/null || { echo "ERROR: Cluster not accessible"; exit 1; }

echo "==> Step 3/5: Bootstrap ArgoCD"
cd "${SCRIPT_DIR}/cluster-bootstrap" && terraform init >/dev/null && terraform apply -auto-approve
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s >/dev/null

echo "==> Step 4/5: Configure External Secrets"
cd "${SCRIPT_DIR}" && just patch-bitwarden

echo "==> Step 5/5: Sync all apps"
kubectl apply -f "${SCRIPT_DIR}/gitops/clusters/homelab/" >/dev/null
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s >/dev/null

echo "✓ Done. ArgoCD: http://192.168.178.91 (admin/\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
