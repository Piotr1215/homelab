# Homelab Backup Strategy

## What Gets Backed Up

| Layer | Status | Location |
|-------|--------|----------|
| **etcd** | ✅ Automated | /var/backups/etcd (local), NFS when mounted |
| **K8s manifests** | ✅ Git | GitHub |
| **PV data** | ✅ Longhorn | NFS (192.168.178.60) |
| **Secrets** | ✅ Bitwarden | Cloud |

**Status:** Implemented 2025-11-10
- Script: `/usr/local/bin/etcd-backup.sh` (also in `scripts/__etcd-backup.sh`)
- Cron: Daily at 3 AM
- Retention:
  - Local: 7 days (simple cleanup)
  - NFS: GFS rotation (Grandfather-Father-Son)
    - Daily: Last 7 days
    - Weekly: Last 4 Sundays (28 days)
    - Monthly: Last 6 months (1st of each month)
    - Max: ~17 backups (~2.8GB)

## Implementation: Automate etcd Backup

**Create backup script:**

```bash
# ssh decoder@192.168.178.87
sudo tee /usr/local/bin/etcd-backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/backups/etcd"
NFS_DIR="/mnt/nas-backups/etcd"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"

mkdir -p "$BACKUP_DIR"

ETCDCTL_API=3 etcdctl snapshot save "$BACKUP_FILE" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-kube-main.pem \
  --key=/etc/ssl/etcd/ssl/admin-kube-main-key.pem

ETCDCTL_API=3 etcdctl snapshot status "$BACKUP_FILE" || exit 1

find "$BACKUP_DIR" -name "*.db" -mtime +7 -delete

if mountpoint -q /mnt/nas-backups; then
  mkdir -p "$NFS_DIR"
  cp "$BACKUP_FILE" "$NFS_DIR/"
  find "$NFS_DIR" -name "*.db" -mtime +30 -delete
fi
EOF

sudo chmod +x /usr/local/bin/etcd-backup.sh
```

**Schedule with cron:**

```bash
sudo crontab -e
# Add:
0 3 * * * /usr/local/bin/etcd-backup.sh 2>&1 | logger -t etcd-backup
```

**Verify:**

```bash
sudo /usr/local/bin/etcd-backup.sh
ls -lh /var/backups/etcd/
```

## Recovery

```bash
export BITWARDEN_MACHINE_ACCOUNT_TOKEN="<token>"
just cluster-restore
```

If VMs don't exist, create first:
```bash
just create-worker-vm pve2 name=kube-main vmid=101
# (repeat for workers)
just ansible-cluster
```

Then run restore script.

## Verification

```bash
# Monthly
ssh decoder@192.168.178.87 'ls -lh /var/backups/etcd/ | tail -3'
kubectl get backups -n longhorn-system --sort-by=.status.lastBackupAt | tail -5

# Quarterly - test restore on spare VM
```

## Sources

- etcd backup: https://etcd.io/docs/v3.5/op-guide/recovery/
- etcd restore: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Certs location: Verified in `/etc/ssl/etcd/ssl/` (Kubespray)
