#!/bin/bash
# Vault Backup Script - CRITICAL for cluster recovery
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="vault-backup-${TIMESTAMP}"
BACKUP_DIR="/home/decoder/dev/homelab/backups/vault"
NAS_BACKUP="/home/decoder/mnt/nas-velero/vault-backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Vault Backup Script ===${NC}"
echo -e "${YELLOW}This is CRITICAL - Vault contains all cluster secrets!${NC}"

# Create backup directories if they don't exist
mkdir -p "${BACKUP_DIR}"
mkdir -p "${NAS_BACKUP}"

# Find Vault PV on nodes
echo -e "${GREEN}Finding Vault data on nodes...${NC}"
for node in 192.168.178.87 192.168.178.88 192.168.178.89; do
    echo "Checking node $node..."
    VAULT_DIRS=$(ssh -o StrictHostKeyChecking=no decoder@$node "sudo find /opt/local-path-provisioner -name '*vault_data-vault-0' 2>/dev/null" || true)
    
    if [ ! -z "$VAULT_DIRS" ]; then
        for dir in $VAULT_DIRS; do
            echo -e "${GREEN}Found Vault data at $node:$dir${NC}"
            
            # Create backup on node
            ssh -o StrictHostKeyChecking=no decoder@$node "sudo tar czf /tmp/${BACKUP_NAME}.tar.gz $dir 2>/dev/null"
            
            # Copy to local
            scp decoder@$node:/tmp/${BACKUP_NAME}.tar.gz ${BACKUP_DIR}/${BACKUP_NAME}-${node}.tar.gz
            
            # Copy to NAS
            cp ${BACKUP_DIR}/${BACKUP_NAME}-${node}.tar.gz ${NAS_BACKUP}/
            
            # Cleanup temp file
            ssh -o StrictHostKeyChecking=no decoder@$node "sudo rm /tmp/${BACKUP_NAME}.tar.gz"
            
            echo -e "${GREEN}✓ Backed up to:${NC}"
            echo "  - ${BACKUP_DIR}/${BACKUP_NAME}-${node}.tar.gz"
            echo "  - ${NAS_BACKUP}/${BACKUP_NAME}-${node}.tar.gz"
        done
    fi
done

# Also backup Vault tokens and keys from .envrc
echo -e "${GREEN}Backing up Vault credentials...${NC}"
grep -E "VAULT_ROOT_TOKEN|VAULT_UNSEAL_KEY|VAULT_ADDR" /home/decoder/dev/homelab/.envrc > ${BACKUP_DIR}/vault-credentials-${TIMESTAMP}.txt
cp ${BACKUP_DIR}/vault-credentials-${TIMESTAMP}.txt ${NAS_BACKUP}/

# List recent backups
echo -e "${GREEN}=== Recent Vault Backups ===${NC}"
ls -lht ${BACKUP_DIR} | head -5

echo -e "${GREEN}✓ Vault backup completed successfully!${NC}"
echo -e "${YELLOW}Remember: These backups contain ALL your secrets - keep them secure!${NC}"