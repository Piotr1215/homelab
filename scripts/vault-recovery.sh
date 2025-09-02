#!/bin/bash
# Vault Recovery & Setup Automation Script
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
# Use environment variables from .envrc
VAULT_UNSEAL_KEY="${VAULT_UNSEAL_KEY:-}"
VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}"

# Validate required environment variables
if [[ -z "$VAULT_UNSEAL_KEY" || -z "$VAULT_ROOT_TOKEN" ]]; then
    echo -e "${RED}Error: VAULT_UNSEAL_KEY and VAULT_ROOT_TOKEN must be set in .envrc${NC}"
    exit 1
fi

echo -e "${BLUE}=== Vault Recovery & Setup Script ===${NC}"

# Function to check if Vault pod is running
check_vault_running() {
    kubectl get pod $VAULT_POD -n $VAULT_NAMESPACE &>/dev/null
}

# Function to check if Vault is sealed
check_vault_sealed() {
    local sealed=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
    [ "$sealed" = "true" ]
}

# Function to unseal Vault
unseal_vault() {
    echo -e "${GREEN}Unsealing Vault...${NC}"
    kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault operator unseal $VAULT_UNSEAL_KEY
}

# Function to setup essential secrets
setup_secrets() {
    echo -e "${GREEN}Setting up essential secrets in Vault...${NC}"
    
    # Login to Vault
    kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault login $VAULT_ROOT_TOKEN >/dev/null
    
    # Homepage secrets
    kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault kv put secret/homepage/allowed-hosts \
        HOMEPAGE_ALLOWED_HOSTS="192.168.178.91,localhost,homepage.local"
    
    # MinIO secrets (if they don't exist)
    if ! kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault kv get secret/minio >/dev/null 2>&1; then
        kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault kv put secret/minio \
            root-user=minio \
            root-password=minio123
    fi
    
    echo -e "${GREEN}✓ Essential secrets configured${NC}"
}

# Function to update vault-token secrets
update_vault_tokens() {
    echo -e "${GREEN}Updating vault-token secrets in namespaces...${NC}"
    
    for ns in default homepage minio; do
        # Delete existing secret if it exists
        kubectl delete secret vault-token -n $ns 2>/dev/null || true
        # Create new secret with correct token
        kubectl create secret generic vault-token \
            --from-literal=token=$VAULT_ROOT_TOKEN \
            -n $ns
        echo -e "  ✓ Updated vault-token in $ns"
    done
}

# Function to restart ESO
restart_eso() {
    echo -e "${GREEN}Restarting External Secrets Operator...${NC}"
    kubectl rollout restart deployment -n external-secrets
    sleep 10
}

# Function to check ESO health
check_eso_health() {
    echo -e "${GREEN}Checking ESO SecretStore health...${NC}"
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        local ready_stores=$(kubectl get secretstores -A -o json | jq -r '.items[] | select(.status.conditions[0].status == "True") | .metadata.name' | wc -l)
        local total_stores=$(kubectl get secretstores -A --no-headers | wc -l)
        
        if [ "$ready_stores" -eq "$total_stores" ] && [ "$total_stores" -gt 0 ]; then
            echo -e "${GREEN}✓ All SecretStores are healthy${NC}"
            kubectl get secretstores -A
            return 0
        fi
        
        echo -e "${YELLOW}Waiting for SecretStores to become healthy... ($ready_stores/$total_stores ready)${NC}"
        sleep 5
        ((attempt++))
    done
    
    echo -e "${RED}⚠ Some SecretStores are not healthy after ${max_attempts} attempts${NC}"
    kubectl get secretstores -A
    return 1
}

# Main execution
main() {
    echo -e "${BLUE}Starting Vault recovery process...${NC}"
    
    # Wait for Vault pod
    echo -e "${GREEN}Waiting for Vault pod to be running...${NC}"
    while ! check_vault_running; do
        echo -e "${YELLOW}Waiting for Vault pod...${NC}"
        sleep 5
    done
    
    # Unseal if needed
    if check_vault_sealed; then
        unseal_vault
    else
        echo -e "${GREEN}✓ Vault is already unsealed${NC}"
    fi
    
    # Setup secrets
    setup_secrets
    
    # Update vault-token secrets
    update_vault_tokens
    
    # Restart ESO
    restart_eso
    
    # Check ESO health
    if check_eso_health; then
        echo -e "${GREEN}✓ Vault recovery completed successfully!${NC}"
        echo -e "${BLUE}Secrets should now be available to applications${NC}"
    else
        echo -e "${YELLOW}⚠ Recovery completed but some issues remain${NC}"
    fi
    
    # Show service IPs
    echo -e "${BLUE}=== Service IPs ===${NC}"
    kubectl get svc -A | grep LoadBalancer | grep -E "homepage|vault-ui|argocd-server"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi