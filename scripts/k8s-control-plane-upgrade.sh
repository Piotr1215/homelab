#!/bin/bash
#####################################################################
# Kubernetes Control Plane Upgrade Script
#
# This script automates the control plane upgrade process following
# official Kubernetes kubeadm upgrade procedures.
#
# Features:
# - Interactive and non-interactive modes
# - Safety checks and validations
# - Automatic or manual node draining
# - Component version verification
# - Rollback capability tracking
# - Support for both Debian/Ubuntu and RHEL/CentOS
#
# Usage:
#   Interactive: ./k8s-control-plane-upgrade.sh <target-version>
#   Non-interactive: ./k8s-control-plane-upgrade.sh <target-version> --yes
#
# Example: ./k8s-control-plane-upgrade.sh v1.33.0
#
# IMPORTANT: Run on control plane nodes only!
#####################################################################

set -euo pipefail

# Configuration
TARGET_VERSION="${1:-}"
AUTO_APPROVE="${2:-}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/kubernetes}"
LOG_FILE="${LOG_FILE:-/tmp/k8s-cp-upgrade-$(date +%Y%m%d-%H%M%S).log}"
DRY_RUN="${DRY_RUN:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${MAGENTA}===================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}===================================================${NC}\n" | tee -a "$LOG_FILE"
}

# Confirmation prompt
confirm() {
    if [ "$AUTO_APPROVE" = "--yes" ] || [ "$AUTO_APPROVE" = "-y" ]; then
        return 0
    fi

    local prompt="${1:-Are you sure?}"
    read -p "$(echo -e ${YELLOW}${prompt}${NC} [y/N]: )" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Detect OS type
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "Cannot detect OS type"
        exit 1
    fi

    log_info "Detected OS: $OS"
}

# Prerequisite checks
check_prerequisites() {
    log_section "Checking Prerequisites"

    # Verify running on control plane node
    if ! kubectl get nodes -l node-role.kubernetes.io/control-plane &> /dev/null; then
        log_error "This script should be run on a control plane node"
        exit 1
    fi

    # Check if this is a control plane node
    local hostname=$(hostname)
    if ! kubectl get node "$hostname" -o jsonpath='{.metadata.labels}' | grep -q "node-role.kubernetes.io/control-plane"; then
        log_error "Current node ($hostname) is not a control plane node"
        exit 1
    fi
    log_success "Running on control plane node: $hostname"

    # Check required commands
    local required_commands=("kubectl" "kubeadm")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    log_success "All required commands are available"

    # Check if user has sudo privileges
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
    log_success "Sudo privileges verified"

    # Create backup directory
    mkdir -p "$BACKUP_DIR" || log_error "Cannot create backup directory"
}

# Check current versions
check_current_version() {
    log_section "Checking Current Version"

    CURRENT_VERSION=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
    CURRENT_KUBEADM=$(kubeadm version -o short)
    CURRENT_KUBELET=$(kubelet --version | awk '{print $2}')
    CURRENT_KUBECTL=$(kubectl version --client --short | awk '{print $3}')

    log_info "Current cluster version: $CURRENT_VERSION"
    log_info "Current kubeadm version: $CURRENT_KUBEADM"
    log_info "Current kubelet version: $CURRENT_KUBELET"
    log_info "Current kubectl version: $CURRENT_KUBECTL"

    # Save current versions
    cat > "$BACKUP_DIR/pre-upgrade-versions.txt" <<EOF
CLUSTER_VERSION=$CURRENT_VERSION
KUBEADM_VERSION=$CURRENT_KUBEADM
KUBELET_VERSION=$CURRENT_KUBELET
KUBECTL_VERSION=$CURRENT_KUBECTL
UPGRADE_DATE=$(date)
EOF
}

# Validate target version
validate_target_version() {
    log_section "Validating Target Version"

    if [ -z "$TARGET_VERSION" ]; then
        log_error "Target version not specified"
        echo "Usage: $0 <target-version> [--yes]"
        exit 1
    fi

    log_info "Target version: $TARGET_VERSION"

    # Extract minor versions
    local current_minor=$(echo "$CURRENT_VERSION" | cut -d. -f2)
    local target_minor=$(echo "$TARGET_VERSION" | cut -d. -f2)

    # Check for skipped versions
    local version_diff=$((target_minor - current_minor))
    if [ "$version_diff" -gt 1 ]; then
        log_error "Cannot skip minor versions! Current: 1.${current_minor}, Target: 1.${target_minor}"
        log_error "Must upgrade sequentially through each minor version"
        exit 1
    elif [ "$version_diff" -lt 0 ]; then
        log_error "Target version is older than current version!"
        exit 1
    fi

    log_success "Version validation passed"
}

# Determine package version string
get_package_version() {
    local k8s_version="$1"
    local minor=$(echo "$k8s_version" | cut -d. -f2)

    # Remove 'v' prefix and format for package managers
    local version_number="${k8s_version#v}"

    case "$OS" in
        ubuntu|debian)
            # Format: 1.33.0-1.1
            echo "${version_number}-*"
            ;;
        centos|rhel|fedora)
            # Format: 1.33.0-0
            echo "${version_number}-*"
            ;;
        *)
            echo "$version_number"
            ;;
    esac
}

# Upgrade kubeadm package
upgrade_kubeadm() {
    log_section "Upgrading kubeadm"

    local pkg_version=$(get_package_version "$TARGET_VERSION")
    log_info "Package version string: $pkg_version"

    # Update package repository for new minor version
    local target_minor=$(echo "$TARGET_VERSION" | cut -d. -f2)

    case "$OS" in
        ubuntu|debian)
            log_info "Updating Kubernetes apt repository..."
            if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
                sudo sed -i "s|/v1\.[0-9]*/deb/|/v1.${target_minor}/deb/|g" /etc/apt/sources.list.d/kubernetes.list
                log_success "Repository updated"
            fi

            log_info "Unholding kubeadm package..."
            sudo apt-mark unhold kubeadm

            log_info "Updating package cache..."
            sudo apt-get update -qq

            log_info "Installing kubeadm ${pkg_version}..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubeadm=${pkg_version}"
            else
                sudo apt-get install -y kubeadm="${pkg_version}"
            fi

            log_info "Holding kubeadm package..."
            sudo apt-mark hold kubeadm
            ;;

        centos|rhel|fedora)
            log_info "Updating Kubernetes yum repository..."
            if [ -f /etc/yum.repos.d/kubernetes.repo ]; then
                sudo sed -i "s|/v1\.[0-9]*/rpm/|/v1.${target_minor}/rpm/|g" /etc/yum.repos.d/kubernetes.repo
            fi

            log_info "Installing kubeadm ${pkg_version}..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubeadm-${pkg_version}"
            else
                sudo yum install -y kubeadm-"${pkg_version}" --disableexcludes=kubernetes
            fi
            ;;

        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    # Verify kubeadm version
    local new_kubeadm=$(kubeadm version -o short)
    log_success "kubeadm upgraded to: $new_kubeadm"
}

# Run kubeadm upgrade plan
run_upgrade_plan() {
    log_section "Running kubeadm Upgrade Plan"

    log_info "Checking available upgrades..."

    if sudo kubeadm upgrade plan 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Upgrade plan completed"

        if ! confirm "Proceed with the upgrade?"; then
            log_warning "Upgrade cancelled by user"
            exit 0
        fi
    else
        log_error "Upgrade plan failed"
        exit 1
    fi
}

# Determine if this is the first control plane
is_first_control_plane() {
    local hostname=$(hostname)
    local control_plane_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
    local first_node=$(echo "$control_plane_nodes" | head -n1)

    if [ "$hostname" = "$first_node" ]; then
        return 0
    else
        return 1
    fi
}

# Apply kubeadm upgrade
apply_upgrade() {
    log_section "Applying kubeadm Upgrade"

    if is_first_control_plane; then
        log_info "This is the first control plane node"
        log_info "Running: kubeadm upgrade apply $TARGET_VERSION"

        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY RUN] Would run: sudo kubeadm upgrade apply $TARGET_VERSION --yes"
        else
            if sudo kubeadm upgrade apply "$TARGET_VERSION" --yes 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Control plane upgrade applied successfully"
            else
                log_error "kubeadm upgrade apply failed!"
                log_error "Check logs at: $LOG_FILE"
                exit 1
            fi
        fi
    else
        log_info "This is an additional control plane node"
        log_info "Running: kubeadm upgrade node"

        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY RUN] Would run: sudo kubeadm upgrade node"
        else
            if sudo kubeadm upgrade node 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Control plane node upgraded successfully"
            else
                log_error "kubeadm upgrade node failed!"
                exit 1
            fi
        fi
    fi
}

# Drain the node
drain_node() {
    log_section "Draining Node"

    local hostname=$(hostname)
    log_info "Draining node: $hostname"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would drain node: $hostname"
        return 0
    fi

    if confirm "Drain node $hostname? This will evict all pods."; then
        if kubectl drain "$hostname" --ignore-daemonsets --delete-emptydir-data 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Node drained successfully"
        else
            log_error "Failed to drain node"
            if ! confirm "Continue anyway?"; then
                exit 1
            fi
        fi
    else
        log_warning "Skipping node drain. Manual drain recommended."
    fi
}

# Upgrade kubelet and kubectl
upgrade_kubelet_kubectl() {
    log_section "Upgrading kubelet and kubectl"

    local pkg_version=$(get_package_version "$TARGET_VERSION")

    case "$OS" in
        ubuntu|debian)
            log_info "Unholding kubelet and kubectl packages..."
            sudo apt-mark unhold kubelet kubectl

            log_info "Installing kubelet=${pkg_version} kubectl=${pkg_version}..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubelet=${pkg_version} kubectl=${pkg_version}"
            else
                sudo apt-get install -y kubelet="${pkg_version}" kubectl="${pkg_version}"
            fi

            log_info "Holding kubelet and kubectl packages..."
            sudo apt-mark hold kubelet kubectl
            ;;

        centos|rhel|fedora)
            log_info "Installing kubelet-${pkg_version} kubectl-${pkg_version}..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubelet-${pkg_version} kubectl-${pkg_version}"
            else
                sudo yum install -y kubelet-"${pkg_version}" kubectl-"${pkg_version}" --disableexcludes=kubernetes
            fi
            ;;
    esac

    # Restart kubelet
    log_info "Restarting kubelet..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restart kubelet"
    else
        sudo systemctl daemon-reload
        sudo systemctl restart kubelet
    fi

    # Wait for kubelet to be ready
    log_info "Waiting for kubelet to be ready..."
    sleep 10

    # Check kubelet status
    if sudo systemctl is-active --quiet kubelet; then
        log_success "kubelet is running"
    else
        log_error "kubelet failed to start!"
        log_error "Check status: sudo systemctl status kubelet"
        log_error "Check logs: sudo journalctl -xeu kubelet"
        exit 1
    fi

    # Verify versions
    local new_kubelet=$(kubelet --version | awk '{print $2}')
    local new_kubectl=$(kubectl version --client --short 2>/dev/null | awk '{print $3}')
    log_success "kubelet upgraded to: $new_kubelet"
    log_success "kubectl upgraded to: $new_kubectl"
}

# Uncordon the node
uncordon_node() {
    log_section "Uncordoning Node"

    local hostname=$(hostname)
    log_info "Uncordoning node: $hostname"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would uncordon node: $hostname"
        return 0
    fi

    if kubectl uncordon "$hostname" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Node uncordoned successfully"
    else
        log_error "Failed to uncordon node"
        exit 1
    fi
}

# Verify upgrade
verify_upgrade() {
    log_section "Verifying Upgrade"

    local hostname=$(hostname)

    # Check node version
    log_info "Checking node version..."
    local node_version=$(kubectl get node "$hostname" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
    log_info "Node version: $node_version"

    if [[ "$node_version" == "$TARGET_VERSION" ]]; then
        log_success "Node version matches target version"
    else
        log_warning "Node version ($node_version) does not match target ($TARGET_VERSION)"
    fi

    # Check node status
    log_info "Checking node status..."
    local node_status=$(kubectl get node "$hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    if [ "$node_status" = "True" ]; then
        log_success "Node is Ready"
    else
        log_error "Node is not Ready!"
        kubectl get node "$hostname"
        exit 1
    fi

    # Check system pods
    log_info "Checking system pods..."
    kubectl get pods -n kube-system -o wide | grep "$hostname" | tee -a "$LOG_FILE"

    # Save post-upgrade state
    cat > "$BACKUP_DIR/post-upgrade-versions.txt" <<EOF
NODE=$hostname
CLUSTER_VERSION=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
KUBEADM_VERSION=$(kubeadm version -o short)
KUBELET_VERSION=$(kubelet --version | awk '{print $2}')
KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null | awk '{print $3}')
UPGRADE_COMPLETED=$(date)
EOF

    log_success "Upgrade verification completed"
}

# Display summary
display_summary() {
    log_section "Upgrade Summary"

    cat <<EOF | tee -a "$LOG_FILE"
Control plane upgrade completed successfully!

Node: $(hostname)
Previous Version: $CURRENT_VERSION
Target Version: $TARGET_VERSION
Current Version: $(kubectl get node $(hostname) -o jsonpath='{.status.nodeInfo.kubeletVersion}')

Logs: $LOG_FILE
Backup: $BACKUP_DIR

Next Steps:
1. Verify cluster health: kubectl get nodes
2. Check system pods: kubectl get pods -n kube-system
3. Upgrade remaining control plane nodes (if any)
4. Upgrade worker nodes
5. Update CNI plugin if needed
6. Verify applications are running correctly

For additional control plane nodes, run:
  sudo kubeadm upgrade node

For worker nodes, use:
  ./k8s-worker-upgrade.sh $TARGET_VERSION
EOF
}

# Main execution
main() {
    log_section "Kubernetes Control Plane Upgrade"
    log_info "Starting upgrade at $(date)"
    log_info "Target version: ${TARGET_VERSION}"
    log_info "Log file: $LOG_FILE"

    # Run upgrade steps
    detect_os
    check_prerequisites
    check_current_version
    validate_target_version

    if ! confirm "Ready to upgrade control plane to $TARGET_VERSION?"; then
        log_warning "Upgrade cancelled"
        exit 0
    fi

    upgrade_kubeadm
    run_upgrade_plan
    apply_upgrade
    drain_node
    upgrade_kubelet_kubectl
    uncordon_node
    verify_upgrade
    display_summary

    log_success "Control plane upgrade completed successfully!"
}

# Run main function
main
