#!/usr/bin/env bash
set -eo pipefail

# Bootstrap Homelab on Kind Cluster
# This script creates a Kind cluster and restores your homelab with Vault

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="${KIND_CLUSTER:-homelab-test}"
TERRAFORM_DIR="/home/decoder/dev/homelab/terraform/bootstrap"
VAULT_SNAPSHOT="${VAULT_SNAPSHOT:-}"
VAULT_CREDENTIALS="${VAULT_CREDENTIALS:-vault-credentials.json}"

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

# Function to create Kind cluster
create_kind_cluster() {
    log "Creating Kind cluster: ${CLUSTER_NAME}"
    
    cat <<EOF | kind create cluster --name ${CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
    - containerPort: 30080
      hostPort: 8080
      protocol: TCP
    - containerPort: 30200
      hostPort: 8200
      protocol: TCP
    - containerPort: 30443
      hostPort: 8443
      protocol: TCP
EOF
    
    # Wait for cluster
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    
    success "Kind cluster created"
}

# Function to install MetalLB (for LoadBalancer support in Kind)
install_metallb() {
    log "Installing MetalLB for LoadBalancer support..."
    
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
    
    # Wait for MetalLB
    kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=90s
    
    # Configure IP pool
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.255.1-172.18.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-advertisement
  namespace: metallb-system
EOF
    
    success "MetalLB installed"
}

# Function to run Terraform bootstrap
run_terraform() {
    log "Running Terraform to install ArgoCD and Vault..."
    
    # Update kubeconfig path for Kind
    export KUBECONFIG="${HOME}/.kube/config"
    
    cd ${TERRAFORM_DIR}
    
    # Create terraform.tfvars for Kind
    cat > terraform.tfvars <<EOF
kubeconfig_path = "${KUBECONFIG}"
vault_loadbalancer_ip = "172.18.255.92"
EOF
    
    # Initialize and apply
    terraform init
    terraform apply -auto-approve
    
    success "Terraform bootstrap complete"
}

# Function to wait for Vault
wait_for_vault() {
    log "Waiting for Vault to be ready..."
    
    # Wait for pod
    kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=300s || error "Vault failed to start"
    
    # Check if initialized
    local status=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || echo '{}')
    local initialized=$(echo "${status}" | grep -o '"initialized":[^,]*' | cut -d: -f2)
    
    if [ "${initialized}" != "true" ]; then
        log "Initializing Vault..."
        kubectl -n vault exec vault-0 -- vault operator init \
            -key-shares=1 \
            -key-threshold=1 \
            -format=json > vault-init-kind.json
        
        # Unseal
        local unseal_key=$(jq -r '.unseal_keys_b64[0]' vault-init-kind.json)
        kubectl -n vault exec vault-0 -- vault operator unseal ${unseal_key}
        
        success "Vault initialized and unsealed"
    fi
}

# Function to restore Vault snapshot
restore_vault_snapshot() {
    local snapshot=$1
    local creds=$2
    
    if [ -z "${snapshot}" ] || [ ! -f "${snapshot}" ]; then
        warning "No Vault snapshot provided or file not found, skipping restore"
        return
    fi
    
    log "Restoring Vault from snapshot: ${snapshot}"
    
    # Use the restore script
    ./vault-restore.sh --credentials ${creds} ${snapshot}
    
    success "Vault restored from snapshot"
}

# Function to deploy ArgoCD apps
deploy_argocd_apps() {
    log "Deploying ArgoCD applications..."
    
    # Apply root app
    kubectl apply -f /home/decoder/dev/homelab/argocd-root/root.yaml
    
    # Wait for apps to sync
    log "Waiting for ArgoCD to sync applications..."
    sleep 30
    
    # Check app status
    kubectl -n argocd get applications
    
    success "ArgoCD applications deployed"
}

# Main execution
main() {
    cat <<EOF
╔════════════════════════════════════════════╗
║    Homelab to Kind Cluster Migration      ║
╚════════════════════════════════════════════╝
EOF
    
    case "${1:-full}" in
        create)
            create_kind_cluster
            install_metallb
            ;;
        terraform)
            run_terraform
            wait_for_vault
            ;;
        restore)
            if [ -z "${VAULT_SNAPSHOT}" ]; then
                error "VAULT_SNAPSHOT environment variable must be set"
            fi
            restore_vault_snapshot "${VAULT_SNAPSHOT}" "${VAULT_CREDENTIALS}"
            ;;
        apps)
            deploy_argocd_apps
            ;;
        full)
            # Full deployment
            create_kind_cluster
            install_metallb
            run_terraform
            wait_for_vault
            
            if [ -n "${VAULT_SNAPSHOT}" ] && [ -f "${VAULT_SNAPSHOT}" ]; then
                restore_vault_snapshot "${VAULT_SNAPSHOT}" "${VAULT_CREDENTIALS}"
            fi
            
            deploy_argocd_apps
            
            echo ""
            success "Homelab deployed to Kind cluster!"
            echo ""
            echo "Access points:"
            echo "  ArgoCD UI: http://localhost:8080"
            echo "  Vault UI:  http://localhost:8200"
            echo ""
            echo "Get ArgoCD admin password:"
            echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
            echo ""
            echo "Vault credentials saved in: vault-init-kind.json (if fresh) or use original credentials"
            ;;
        destroy)
            warning "Destroying Kind cluster: ${CLUSTER_NAME}"
            kind delete cluster --name ${CLUSTER_NAME}
            success "Cluster destroyed"
            ;;
        *)
            echo "Usage: $0 [create|terraform|restore|apps|full|destroy]"
            echo ""
            echo "Commands:"
            echo "  create    - Create Kind cluster with MetalLB"
            echo "  terraform - Run Terraform to install ArgoCD/Vault"
            echo "  restore   - Restore Vault from snapshot (requires VAULT_SNAPSHOT env)"
            echo "  apps      - Deploy ArgoCD applications"
            echo "  full      - Complete deployment (default)"
            echo "  destroy   - Destroy the Kind cluster"
            echo ""
            echo "Environment variables:"
            echo "  KIND_CLUSTER     - Cluster name (default: homelab-test)"
            echo "  VAULT_SNAPSHOT   - Path to Vault snapshot file"
            echo "  VAULT_CREDENTIALS - Path to original Vault credentials"
            exit 1
            ;;
    esac
}

# Run main
main "$@"