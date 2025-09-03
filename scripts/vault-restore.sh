#!/usr/bin/env bash
set -eo pipefail

# Vault Restore Script for Homelab
# This script automates the restoration of Vault from a snapshot

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-vault-credentials.json}"

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to wait for pod to be ready
wait_for_pod() {
    log "Waiting for Vault pod to be ready..."
    kubectl -n ${VAULT_NAMESPACE} wait --for=condition=Ready pod/${VAULT_POD} --timeout=300s || error "Vault pod failed to become ready"
}

# Function to initialize Vault
initialize_vault() {
    log "Initializing Vault..."
    
    # Check if already initialized
    local status=$(kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- vault status -format=json 2>/dev/null || echo '{}')
    local initialized=$(echo "${status}" | grep -o '"initialized":[^,]*' | cut -d: -f2)
    
    if [ "${initialized}" = "true" ]; then
        warning "Vault is already initialized"
        return 0
    fi
    
    # Initialize and save credentials
    kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- vault operator init \
        -key-shares=1 \
        -key-threshold=1 \
        -format=json > ${CREDENTIALS_FILE}.new
    
    success "Vault initialized. New credentials saved to ${CREDENTIALS_FILE}.new"
}

# Function to unseal Vault
unseal_vault() {
    local key_file=$1
    log "Unsealing Vault using ${key_file}..."
    
    local unseal_key=$(jq -r '.unseal_keys_b64[0]' ${key_file})
    
    if [ -z "${unseal_key}" ] || [ "${unseal_key}" = "null" ]; then
        error "No unseal key found in ${key_file}"
    fi
    
    kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- vault operator unseal ${unseal_key} || error "Failed to unseal Vault"
    
    success "Vault unsealed"
}

# Function to restore snapshot
restore_snapshot() {
    local snapshot_file=$1
    local token_file=$2
    
    log "Restoring snapshot: ${snapshot_file}"
    
    # Get root token from credentials
    local root_token=$(jq -r '.root_token' ${token_file})
    
    if [ -z "${root_token}" ] || [ "${root_token}" = "null" ]; then
        error "No root token found in ${token_file}"
    fi
    
    # Copy snapshot to pod
    log "Copying snapshot to Vault pod..."
    kubectl -n ${VAULT_NAMESPACE} cp ${snapshot_file} ${VAULT_POD}:/tmp/restore.snap
    
    # Restore snapshot with force flag
    log "Executing restore..."
    kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- sh -c "
        export VAULT_TOKEN='${root_token}'
        vault operator raft snapshot restore -force /tmp/restore.snap
    " || error "Failed to restore snapshot"
    
    success "Snapshot restored"
    
    # Clean up
    kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- rm -f /tmp/restore.snap
}

# Function to verify restoration
verify_restore() {
    local original_token=$1
    
    log "Verifying restoration..."
    
    # Try to list secrets with original token
    kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- sh -c "
        export VAULT_TOKEN='${original_token}'
        echo '=== Secrets Engines ==='
        vault secrets list
        echo ''
        echo '=== KV Secrets ==='
        vault kv list secret/ 2>/dev/null || echo 'No KV secrets found'
        echo ''
        echo '=== Policies ==='
        vault policy list
    " || warning "Could not verify all resources"
}

# Main restore flow
main() {
    cat <<EOF
╔════════════════════════════════════════════╗
║        Vault Restore from Snapshot        ║
╚════════════════════════════════════════════╝
EOF
    
    # Parse arguments
    case "${1:-}" in
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS] SNAPSHOT_FILE

Options:
  --credentials FILE    Path to original Vault credentials file (default: vault-credentials.json)
  --namespace NS        Kubernetes namespace (default: vault)
  --pod NAME           Vault pod name (default: vault-0)
  --help               Show this help message

Example:
  $0 vault-snapshot-20240101-120000.snap
  $0 --credentials old-vault-creds.json backups/vault-latest.snap
EOF
            exit 0
            ;;
    esac
    
    # Process arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --credentials)
                CREDENTIALS_FILE="$2"
                shift 2
                ;;
            --namespace)
                VAULT_NAMESPACE="$2"
                shift 2
                ;;
            --pod)
                VAULT_POD="$2"
                shift 2
                ;;
            *)
                SNAPSHOT_FILE="$1"
                shift
                ;;
        esac
    done
    
    # Validate snapshot file
    if [ -z "${SNAPSHOT_FILE:-}" ]; then
        error "Snapshot file is required. Use --help for usage."
    fi
    
    if [ ! -f "${SNAPSHOT_FILE}" ]; then
        error "Snapshot file not found: ${SNAPSHOT_FILE}"
    fi
    
    # Check for original credentials
    if [ ! -f "${CREDENTIALS_FILE}" ]; then
        warning "Original credentials file not found: ${CREDENTIALS_FILE}"
        warning "You will need the original root token to access Vault after restore!"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Start restoration process
    log "Starting Vault restoration process..."
    log "Snapshot: ${SNAPSHOT_FILE}"
    log "Namespace: ${VAULT_NAMESPACE}"
    log "Pod: ${VAULT_POD}"
    
    # Wait for pod
    wait_for_pod
    
    # Initialize Vault (creates new credentials)
    initialize_vault
    
    # Unseal with new key
    unseal_vault "${CREDENTIALS_FILE}.new"
    
    # Restore snapshot (using new token, but it will be invalidated)
    restore_snapshot "${SNAPSHOT_FILE}" "${CREDENTIALS_FILE}.new"
    
    # Wait for Vault to restart
    log "Waiting for Vault to restart after restore..."
    sleep 10
    
    # Check Vault status
    local status=$(kubectl -n ${VAULT_NAMESPACE} exec ${VAULT_POD} -- vault status -format=json 2>/dev/null || echo '{}')
    local sealed=$(echo "${status}" | grep -o '"sealed":[^,]*' | cut -d: -f2)
    
    if [ "${sealed}" = "true" ]; then
        log "Vault is sealed after restore (expected)"
        
        # Try to unseal with ORIGINAL key first
        if [ -f "${CREDENTIALS_FILE}" ]; then
            log "Attempting to unseal with original credentials..."
            unseal_vault "${CREDENTIALS_FILE}" || {
                warning "Original key didn't work, trying new key..."
                unseal_vault "${CREDENTIALS_FILE}.new"
            }
        else
            unseal_vault "${CREDENTIALS_FILE}.new"
        fi
    fi
    
    # Verify restoration with original token
    if [ -f "${CREDENTIALS_FILE}" ]; then
        local original_token=$(jq -r '.root_token' ${CREDENTIALS_FILE})
        verify_restore "${original_token}"
    else
        warning "Cannot verify restoration without original credentials"
    fi
    
    success "Vault restoration complete!"
    
    echo ""
    echo "Important notes:"
    echo "1. The snapshot has been restored with all secrets, policies, and tokens"
    echo "2. The ORIGINAL root token is now valid (from before the backup)"
    echo "3. The NEW root token (from initialization) is now INVALID"
    echo "4. Save your credentials securely!"
    
    if [ -f "${CREDENTIALS_FILE}" ]; then
        echo ""
        echo "Original credentials are in: ${CREDENTIALS_FILE}"
        echo "Root Token: $(jq -r '.root_token' ${CREDENTIALS_FILE})"
    fi
}

# Run main function
main "$@"