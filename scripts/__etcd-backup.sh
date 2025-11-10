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

  # GFS rotation: daily (7) + weekly (4) + monthly (6) = ~17 backups max
  cd "$NFS_DIR"

  # Keep daily backups (last 7 days)
  ls -t etcd-snapshot-*.db 2>/dev/null | tail -n +8 | while read -r backup; do
    backup_date=$(echo "$backup" | grep -oP '\d{8}')
    backup_epoch=$(date -d "${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}" +%s)
    age_days=$(( ($(date +%s) - backup_epoch) / 86400 ))
    dow=$(date -d "${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}" +%u)
    dom=$(date -d "${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}" +%d)

    # Keep if: within 7 days OR (Sunday AND within 28 days) OR (1st of month AND within 180 days)
    if [ "$age_days" -le 7 ]; then
      continue  # Keep daily
    elif [ "$dow" -eq 7 ] && [ "$age_days" -le 28 ]; then
      continue  # Keep weekly (Sundays)
    elif [ "$dom" -eq 01 ] && [ "$age_days" -le 180 ]; then
      continue  # Keep monthly (1st of month)
    else
      rm -f "$backup"  # Delete
    fi
  done
fi
