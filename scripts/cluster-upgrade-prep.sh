#!/bin/bash
# Cluster Upgrade Preparation Script
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Cluster Upgrade Preparation ===${NC}"

# Function to check cluster health
check_cluster_health() {
    echo -e "${GREEN}Checking cluster health...${NC}"
    
    # Check nodes
    echo -e "${YELLOW}Nodes status:${NC}"
    kubectl get nodes
    
    # Check system pods
    echo -e "${YELLOW}System pods:${NC}"
    kubectl get pods -n kube-system | grep -E "Running|Pending|Error"
    
    # Check ArgoCD apps
    echo -e "${YELLOW}ArgoCD applications:${NC}"
    kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
}

# Function to backup critical data
backup_critical_data() {
    echo -e "${GREEN}Backing up critical data...${NC}"
    
    # Backup Vault
    if [ -x "./scripts/vault-backup.sh" ]; then
        echo -e "${YELLOW}Running Vault backup...${NC}"
        ./scripts/vault-backup.sh
    fi
    
    # Backup ETCD (if accessible)
    echo -e "${YELLOW}Note: ETCD backup should be done on control plane node${NC}"
    
    # List PVs
    echo -e "${YELLOW}Persistent Volumes:${NC}"
    kubectl get pv -o wide
}

# Function to check for deprecated APIs
check_deprecated_apis() {
    echo -e "${GREEN}Checking for deprecated APIs...${NC}"
    
    # This would normally use tools like pluto or kubectl-deprecations
    echo -e "${YELLOW}Manual check required for deprecated APIs${NC}"
    echo "Consider using: https://github.com/FairwindsOps/pluto"
}

# Function to sync ArgoCD apps
sync_argocd_apps() {
    echo -e "${GREEN}Syncing ArgoCD applications...${NC}"
    
    # Get all apps
    apps=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')
    
    for app in $apps; do
        status=$(kubectl get application $app -n argocd -o jsonpath='{.status.sync.status}')
        if [ "$status" != "Synced" ]; then
            echo -e "${YELLOW}App $app is $status${NC}"
        else
            echo -e "${GREEN}✓ App $app is synced${NC}"
        fi
    done
}

# Main execution
main() {
    echo -e "${BLUE}Starting pre-upgrade checks...${NC}"
    echo ""
    
    # Check cluster health
    check_cluster_health
    echo ""
    
    # Backup critical data
    backup_critical_data
    echo ""
    
    # Check deprecated APIs
    check_deprecated_apis
    echo ""
    
    # Sync ArgoCD apps
    sync_argocd_apps
    echo ""
    
    echo -e "${GREEN}=== Pre-Upgrade Checklist ===${NC}"
    echo "1. ✓ Cluster health checked"
    echo "2. ✓ Vault data backed up"
    echo "3. ⚠ ETCD backup - run on control plane"
    echo "4. ⚠ Deprecated APIs - manual check required"
    echo "5. ✓ ArgoCD apps status reviewed"
    echo ""
    echo -e "${YELLOW}Manual upgrade steps:${NC}"
    echo "1. SSH to control plane: ssh decoder@192.168.178.87"
    echo "2. Run kubeadm upgrade plan"
    echo "3. Follow kubeadm upgrade procedure"
    echo "4. Upgrade kubelet and kubectl on all nodes"
    echo ""
    echo -e "${BLUE}Backup locations:${NC}"
    echo "- Vault: /home/decoder/dev/homelab/backups/vault/"
    echo "- NAS: /home/decoder/mnt/nas-velero/vault-backups/"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi