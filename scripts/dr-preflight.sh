#!/usr/bin/env bash
# dr-preflight.sh - DR readiness check
set -eo pipefail

echo "=== DR Pre-Flight Check ==="

# 1. etcd backup recency
echo -n "[etcd backup] "
LATEST=$(ssh decoder@192.168.178.87 'ls -t /var/backups/etcd/*.db 2>/dev/null | head -1' 2>/dev/null)
if [[ -z "$LATEST" ]]; then
  echo "FAIL - No backups found"
else
  AGE=$(ssh decoder@192.168.178.87 "stat -c %Y '$LATEST'" 2>/dev/null)
  NOW=$(date +%s)
  HOURS=$(( (NOW - AGE) / 3600 ))
  [[ $HOURS -lt 25 ]] && echo "OK ($HOURS hours old)" || echo "WARN - $HOURS hours old"
fi

# 2. NFS mount
echo -n "[NFS mount] "
ssh decoder@192.168.178.87 'mountpoint -q /mnt/nas-backups' 2>/dev/null && echo "OK" || echo "FAIL - not mounted"

# 3. Longhorn backups
echo -n "[Longhorn backups] "
BACKUPS=$(kubectl get backups.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
[[ $BACKUPS -gt 0 ]] && echo "OK ($BACKUPS backups)" || echo "FAIL - no backups"

# 4. Node health
echo -n "[Nodes] "
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l || true)
[[ $NOT_READY -eq 0 ]] && echo "OK (all Ready)" || echo "WARN - $NOT_READY not ready"

# 5. ArgoCD sync
echo -n "[ArgoCD] "
OUT_OF_SYNC=$(kubectl get applications -n argocd --no-headers 2>/dev/null | grep -v "Synced" | wc -l || true)
[[ $OUT_OF_SYNC -eq 0 ]] && echo "OK (all synced)" || echo "WARN - $OUT_OF_SYNC out of sync"

# 6. Bitwarden ESO
echo -n "[Bitwarden ESO] "
kubectl get clustersecretstore bitwarden-secretsmanager -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True && echo "OK" || echo "FAIL - check token"

echo "=== End Pre-Flight ==="
