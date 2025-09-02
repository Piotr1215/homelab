#!/bin/bash
# Kubernetes Upgrade Script using Kubespray
# Wrapper around Kubespray's battle-tested upgrade playbook

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="/home/decoder/dev/homelab"
KUBESPRAY_DIR="$HOMELAB_DIR/kubespray"
INVENTORY="$KUBESPRAY_DIR/inventory/homelab"
GROUP_VARS="$INVENTORY/group_vars/all/all.yml"
ANSIBLE_CONFIG="$KUBESPRAY_DIR/ansible.cfg"

# Function to get current cluster version
get_current_version() {
    kubectl version --output=json | jq -r '.serverVersion.gitVersion' | sed 's/^v//'
}

# Function to get available versions
get_next_version() {
    local current="$1"
    local current_major=$(echo "$current" | cut -d. -f1)
    local current_minor=$(echo "$current" | cut -d. -f2)
    local current_patch=$(echo "$current" | cut -d. -f3)
    
    # Get all available versions from GitHub
    local available_versions=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases 2>/dev/null | \
        grep '"tag_name"' | \
        grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | \
        sort -V)
    
    # First check for patch updates in current minor version
    local current_minor_latest=$(echo "$available_versions" | \
        grep "^v${current_major}\.${current_minor}\." | \
        tail -1)
    
    # Check if there's a newer patch in the current minor version
    if [ -n "$current_minor_latest" ] && [ "$current_minor_latest" != "v${current}" ]; then
        echo "$current_minor_latest"
        return
    fi
    
    # No patch update, check for next minor version
    local next_minor=$((current_minor + 1))
    
    # Find the latest patch of the next minor version
    local next_minor_latest=$(echo "$available_versions" | \
        grep "^v${current_major}\.${next_minor}\." | \
        tail -1)
    
    if [ -n "$next_minor_latest" ]; then
        echo "$next_minor_latest"
    else
        echo ""
    fi
}

# Function to perform backup
backup_cluster() {
    local version="$1"
    echo -e "${YELLOW}Creating backup before upgrade to ${version}...${NC}"
    
    if command -v just &> /dev/null; then
        cd "$HOMELAB_DIR" && just backup-velero "before-k8s-upgrade-to-${version}"
    else
        echo -e "${YELLOW}Warning: 'just' command not found. Please backup manually.${NC}"
        read -p "Have you backed up the cluster? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${RED}Aborting upgrade. Please backup first.${NC}"
            exit 1
        fi
    fi
}

# Function to update Kubespray configuration
update_kubespray_config() {
    local target_version="$1"
    
    echo -e "${BLUE}Updating Kubespray configuration...${NC}"
    
    # Backup current config
    cp "$GROUP_VARS" "${GROUP_VARS}.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Update kube_version in group_vars (remove 'v' prefix for Kubespray v2.28+)
    local version_no_v="${target_version#v}"
    sed -i "s/^kube_version:.*/kube_version: ${version_no_v}/" "$GROUP_VARS"
    
    echo -e "${GREEN}  ✓ Updated kube_version to ${version_no_v}${NC}"
}

# Function to perform the upgrade using Kubespray
perform_upgrade() {
    local target_version="$1"
    local current_version="$2"
    
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    Kubernetes Cluster Upgrade (via Kubespray)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Current Version:${NC} v${current_version}"
    echo -e "${BLUE}Target Version:${NC}  ${target_version}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo
    
    # Update Kubespray configuration
    update_kubespray_config "$target_version"
    
    # Run Kubespray upgrade playbook
    echo -e "${YELLOW}Running Kubespray upgrade playbook...${NC}"
    echo -e "${YELLOW}This will handle the entire upgrade process safely.${NC}"
    
    cd "$KUBESPRAY_DIR"
    
    # Set ansible environment
    export ANSIBLE_CONFIG="$ANSIBLE_CONFIG"
    export ANSIBLE_HOST_KEY_CHECKING=False
    
    # Run the upgrade (remove 'v' prefix for Kubespray v2.28+)
    local version_no_v="${target_version#v}"
    ansible-playbook -i "$INVENTORY/inventory.ini" \
        --become --become-user=root \
        upgrade-cluster.yml \
        -e "kube_version=${version_no_v}" \
        -e "upgrade_cluster_setup=true" \
        -e "drain_nodes=true" \
        -e "drain_pod_selector=''" \
        -e "drain_timeout=300" \
        -e "drain_grace_period=30" \
        -e "drain_retries=3" \
        -e "ignore_assert_errors=true" \
        -v
    
    local upgrade_result=$?
    
    if [ $upgrade_result -eq 0 ]; then
        echo -e "${GREEN}✓ Kubespray upgrade completed successfully!${NC}"
    else
        echo -e "${RED}✗ Kubespray upgrade failed with exit code $upgrade_result${NC}"
        echo -e "${YELLOW}Please check the logs above for details.${NC}"
        return $upgrade_result
    fi
}

# Function for post-upgrade tasks
post_upgrade_tasks() {
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    Post-Upgrade Tasks${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    
    # Unseal Vault if it exists
    if kubectl get ns vault &>/dev/null; then
        echo -e "${YELLOW}Checking Vault status...${NC}"
        if [ -n "$VAULT_UNSEAL_KEY" ]; then
            kubectl exec -n vault vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY" 2>/dev/null || echo "  Vault is already unsealed or not ready"
        else
            echo -e "${YELLOW}  VAULT_UNSEAL_KEY not found in environment${NC}"
        fi
    fi
    
    # Check cluster status
    echo -e "${BLUE}Cluster Status:${NC}"
    kubectl get nodes
    
    # Check for problematic pods
    echo -e "${BLUE}Checking for pod issues...${NC}"
    local problem_pods=$(kubectl get pods -A | grep -v Running | grep -v Completed | grep -v NAMESPACE | wc -l)
    if [ "$problem_pods" -gt 0 ]; then
        echo -e "${YELLOW}  Found $problem_pods pods with issues:${NC}"
        kubectl get pods -A | grep -v Running | grep -v Completed | head -10
    else
        echo -e "${GREEN}  ✓ All pods are healthy!${NC}"
    fi
    
    # Create post-upgrade backup
    echo -e "${YELLOW}Creating post-upgrade backup...${NC}"
    if command -v just &> /dev/null; then
        local new_version=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion')
        cd "$HOMELAB_DIR" && just backup-velero "after-k8s-upgrade-to-${new_version}"
    fi
}

# Main execution
main() {
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  Kubernetes Upgrade Tool (Kubespray Edition)     ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════╝${NC}"
    echo
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found${NC}"
        exit 1
    fi
    
    if ! command -v ansible-playbook &> /dev/null; then
        echo -e "${RED}Error: ansible-playbook not found${NC}"
        echo -e "${YELLOW}Please install Ansible: pip install ansible${NC}"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq not found. Installing...${NC}"
        sudo apt-get install -y jq
    fi
    
    if [ ! -d "$KUBESPRAY_DIR" ]; then
        echo -e "${RED}Error: Kubespray directory not found at $KUBESPRAY_DIR${NC}"
        echo -e "${YELLOW}Please clone Kubespray first:${NC}"
        echo -e "${YELLOW}  git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAY_DIR${NC}"
        exit 1
    fi
    
    # Get current version
    echo -e "${BLUE}Detecting current cluster version...${NC}"
    CURRENT_VERSION=$(get_current_version)
    echo -e "${GREEN}  Current version: v${CURRENT_VERSION}${NC}"
    
    # Handle specific version if provided
    if [ -n "$1" ] && [ "$1" != "--check" ]; then
        NEXT_VERSION="$1"
        echo -e "${BLUE}Target version specified: ${NEXT_VERSION}${NC}"
    else
        # Get next available version
        echo -e "${BLUE}Detecting next available version...${NC}"
        NEXT_VERSION=$(get_next_version "$CURRENT_VERSION")
        
        if [ -z "$NEXT_VERSION" ]; then
            echo -e "${GREEN}✓ Your cluster is already at the latest version!${NC}"
            exit 0
        fi
    fi
    
    # Validate version format
    if ! echo "$NEXT_VERSION" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$"; then
        echo -e "${RED}Error: Invalid version format: $NEXT_VERSION${NC}"
        echo -e "${YELLOW}Expected format: v1.x.y${NC}"
        exit 1
    fi
    
    # Determine upgrade type
    CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
    NEXT_MINOR=$(echo "$NEXT_VERSION" | sed 's/^v//' | cut -d. -f2)
    
    if [ "$CURRENT_MINOR" = "$NEXT_MINOR" ]; then
        echo -e "${YELLOW}  Patch update: ${NEXT_VERSION}${NC}"
    else
        echo -e "${GREEN}  Minor version upgrade: ${NEXT_VERSION}${NC}"
    fi
    echo
    
    # Confirm upgrade
    echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Ready to upgrade from v${CURRENT_VERSION} to ${NEXT_VERSION}${NC}"
    echo -e "${YELLOW}Using Kubespray for safe, idempotent upgrade${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
    read -p "Proceed with upgrade? (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Upgrade cancelled.${NC}"
        exit 0
    fi
    
    # Perform backup
    backup_cluster "$NEXT_VERSION"
    
    # Perform upgrade
    perform_upgrade "$NEXT_VERSION" "$CURRENT_VERSION"
    
    # Post-upgrade tasks
    post_upgrade_tasks
    
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Upgrade completed successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
}

# Function to just check available upgrades
check_upgrades() {
    echo -e "${BLUE}📊 Current Kubernetes Version:${NC}"
    kubectl version --short 2>/dev/null || kubectl version
    echo
    
    CURRENT=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion' | sed 's/^v//')
    CURRENT_MINOR=$(echo "$CURRENT" | cut -d. -f2)
    NEXT_MINOR=$((CURRENT_MINOR + 1))
    
    echo -e "${YELLOW}📦 Checking Available Upgrades...${NC}"
    echo "  Current: v${CURRENT}"
    echo
    
    echo -e "${GREEN}📈 Available Versions:${NC}"
    
    # Get latest releases from GitHub
    curl -s https://api.github.com/repos/kubernetes/kubernetes/releases | \
        grep '"tag_name"' | head -10 | \
        grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | \
        while read version; do
            MINOR=$(echo "$version" | cut -d. -f2 | sed 's/^v//')
            if [ "$MINOR" -eq "$NEXT_MINOR" ]; then
                echo -e "  ${GREEN}✅ $version (next minor - recommended)${NC}"
            elif [ "$MINOR" -gt "$CURRENT_MINOR" ]; then
                SKIP=$((MINOR - CURRENT_MINOR - 1))
                echo -e "  ${YELLOW}⏩ $version (skip $SKIP minor version(s) - not recommended)${NC}"
            fi
        done
    
    echo
    echo -e "${MAGENTA}💡 Kubernetes only supports upgrading one minor version at a time!${NC}"
    echo -e "${MAGENTA}   You should upgrade to v1.${NEXT_MINOR}.x first${NC}"
}

# Check if script is called with --check flag
if [ "$1" == "--check" ]; then
    check_upgrades
    exit 0
fi

# Run main function
main "$@"