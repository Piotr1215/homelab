#!/bin/bash
#####################################################################
# Kubernetes Worker Node Upgrade Script
#
# This script automates worker node upgrade process following
# official Kubernetes kubeadm upgrade procedures.
#
# Features:
# - Safe node draining with pod eviction
# - Automatic package upgrades
# - Version verification
# - Graceful pod rescheduling
# - Support for both Debian/Ubuntu and RHEL/CentOS
# - Batch or single node upgrade modes
#
# Usage:
#   Single node: ./k8s-worker-upgrade.sh <target-version>
#   Multiple nodes: ./k8s-worker-upgrade.sh <target-version> <node1> <node2> ...
#   Interactive: ./k8s-worker-upgrade.sh <target-version> --interactive
#
# Example: ./k8s-worker-upgrade.sh v1.33.0 worker-1
#
# IMPORTANT: Can be run from control plane or worker nodes
#####################################################################

set -euo pipefail

# Configuration
TARGET_VERSION="${1:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
LOG_FILE="${LOG_FILE:-/tmp/k8s-worker-upgrade-$(date +%Y%m%d-%H%M%S).log}"
DRY_RUN="${DRY_RUN:-false}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300s}"
POD_EVICTION_TIMEOUT="${POD_EVICTION_TIMEOUT:-60s}"

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
    if [ "$AUTO_APPROVE" = "true" ]; then
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

# Detect if running on the node to be upgraded or remotely
REMOTE_MODE=false
CURRENT_NODE=$(hostname)

# Parse arguments
parse_arguments() {
    if [ $# -lt 1 ]; then
        log_error "Usage: $0 <target-version> [node-names...] [--interactive]"
        exit 1
    fi

    TARGET_VERSION="$1"
    shift

    # Parse node list or mode flags
    NODES=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --interactive|-i)
                INTERACTIVE_MODE=true
                ;;
            --yes|-y)
                AUTO_APPROVE=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            *)
                NODES+=("$1")
                ;;
        esac
        shift
    done

    # If no nodes specified, assume current node
    if [ ${#NODES[@]} -eq 0 ]; then
        NODES=("$CURRENT_NODE")
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
}

# Check prerequisites
check_prerequisites() {
    log_section "Checking Prerequisites"

    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_success "Connected to cluster"

    # Verify target version
    if [ -z "$TARGET_VERSION" ]; then
        log_error "Target version not specified"
        exit 1
    fi
    log_info "Target version: $TARGET_VERSION"
}

# Get nodes to upgrade
get_worker_nodes() {
    log_section "Identifying Worker Nodes"

    if [ "${INTERACTIVE_MODE:-false}" = "true" ]; then
        log_info "Available worker nodes:"
        kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?@.type==\"Ready\"].status,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage

        read -p "$(echo -e ${YELLOW}Enter node names to upgrade (space-separated):${NC} )" -a NODES

        if [ ${#NODES[@]} -eq 0 ]; then
            log_error "No nodes specified"
            exit 1
        fi
    fi

    log_info "Nodes to upgrade: ${NODES[*]}"

    # Verify nodes exist and are workers
    for node in "${NODES[@]}"; do
        if ! kubectl get node "$node" &> /dev/null; then
            log_error "Node not found: $node"
            exit 1
        fi

        # Check if it's a worker node (not control plane)
        if kubectl get node "$node" -o jsonpath='{.metadata.labels}' | grep -q "node-role.kubernetes.io/control-plane"; then
            log_warning "Node $node is a control plane node! Use k8s-control-plane-upgrade.sh instead"
            if ! confirm "Continue anyway?"; then
                exit 1
            fi
        fi
    done
}

# Check node health before upgrade
check_node_health() {
    local node="$1"

    log_info "Checking health of node: $node"

    # Check node status
    local node_ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$node_ready" != "True" ]; then
        log_warning "Node $node is not Ready!"
        kubectl get node "$node"
        if ! confirm "Continue with unhealthy node?"; then
            return 1
        fi
    fi

    # Check for pressure conditions
    local conditions=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')
    if echo "$conditions" | grep -q "MemoryPressure\|DiskPressure\|PIDPressure"; then
        log_warning "Node $node has pressure conditions: $conditions"
    fi

    # Show current version
    local current_version=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
    log_info "Current version of $node: $current_version"

    # Check running pods
    local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers 2>/dev/null | wc -l)
    log_info "Pods running on $node: $pod_count"

    return 0
}

# Cordon node
cordon_node() {
    local node="$1"

    log_info "Cordoning node: $node"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would cordon node: $node"
        return 0
    fi

    if kubectl cordon "$node" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Node $node cordoned"
    else
        log_error "Failed to cordon node $node"
        return 1
    fi
}

# Drain node
drain_node() {
    local node="$1"

    log_section "Draining Node: $node"

    log_info "This will evict all pods from the node"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would drain node: $node"
        return 0
    fi

    # Show pods that will be evicted
    log_info "Pods to be evicted:"
    kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" -o wide | tee -a "$LOG_FILE"

    if ! confirm "Proceed with draining $node?"; then
        log_warning "Drain cancelled"
        return 1
    fi

    log_info "Draining node $node (timeout: $DRAIN_TIMEOUT)..."

    if kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --timeout="$DRAIN_TIMEOUT" \
        --grace-period=30 \
        --pod-selector='app!=critical' 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Node $node drained successfully"
    else
        log_error "Failed to drain node $node"
        log_warning "Some pods may not have been evicted"

        if ! confirm "Continue with upgrade anyway?"; then
            # Uncordon the node before exiting
            kubectl uncordon "$node"
            return 1
        fi
    fi

    # Wait for pods to be rescheduled
    log_info "Waiting for pods to be rescheduled..."
    sleep 10
}

# Determine package version
get_package_version() {
    local k8s_version="$1"

    # Remove 'v' prefix and format for package managers
    local version_number="${k8s_version#v}"

    case "$OS" in
        ubuntu|debian)
            echo "${version_number}-*"
            ;;
        centos|rhel|fedora)
            echo "${version_number}-*"
            ;;
        *)
            echo "$version_number"
            ;;
    esac
}

# Execute upgrade on node
upgrade_node_packages() {
    local node="$1"

    log_section "Upgrading Packages on Node: $node"

    local pkg_version=$(get_package_version "$TARGET_VERSION")
    local target_minor=$(echo "$TARGET_VERSION" | cut -d. -f2)

    # Check if we're running on the target node
    if [ "$node" = "$CURRENT_NODE" ]; then
        # Local upgrade
        log_info "Performing local upgrade on $node"

        case "$OS" in
            ubuntu|debian)
                log_info "Updating Kubernetes apt repository..."
                if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
                    sudo sed -i "s|/v1\.[0-9]*/deb/|/v1.${target_minor}/deb/|g" /etc/apt/sources.list.d/kubernetes.list
                fi

                log_info "Upgrading kubeadm..."
                sudo apt-mark unhold kubeadm
                sudo apt-get update -qq
                sudo apt-get install -y kubeadm="${pkg_version}"
                sudo apt-mark hold kubeadm

                log_info "Upgrading node configuration..."
                if [ "$DRY_RUN" = "true" ]; then
                    log_info "[DRY RUN] Would run: sudo kubeadm upgrade node"
                else
                    sudo kubeadm upgrade node
                fi

                log_info "Upgrading kubelet and kubectl..."
                sudo apt-mark unhold kubelet kubectl
                sudo apt-get install -y kubelet="${pkg_version}" kubectl="${pkg_version}"
                sudo apt-mark hold kubelet kubectl

                log_info "Restarting kubelet..."
                sudo systemctl daemon-reload
                sudo systemctl restart kubelet
                ;;

            centos|rhel|fedora)
                log_info "Updating Kubernetes yum repository..."
                if [ -f /etc/yum.repos.d/kubernetes.repo ]; then
                    sudo sed -i "s|/v1\.[0-9]*/rpm/|/v1.${target_minor}/rpm/|g" /etc/yum.repos.d/kubernetes.repo
                fi

                log_info "Upgrading kubeadm..."
                sudo yum install -y kubeadm-"${pkg_version}" --disableexcludes=kubernetes

                log_info "Upgrading node configuration..."
                if [ "$DRY_RUN" = "true" ]; then
                    log_info "[DRY RUN] Would run: sudo kubeadm upgrade node"
                else
                    sudo kubeadm upgrade node
                fi

                log_info "Upgrading kubelet and kubectl..."
                sudo yum install -y kubelet-"${pkg_version}" kubectl-"${pkg_version}" --disableexcludes=kubernetes

                log_info "Restarting kubelet..."
                sudo systemctl daemon-reload
                sudo systemctl restart kubelet
                ;;
        esac
    else
        # Remote upgrade via SSH
        log_warning "Remote upgrade detected for node: $node"
        log_warning "For security, manual upgrade recommended:"
        log_info "SSH to $node and run:"
        log_info "  curl -fsSL https://github.com/yourusername/homelab/raw/main/scripts/k8s-worker-upgrade.sh | bash -s -- $TARGET_VERSION"
        log_info "OR copy this script to the node and execute locally"

        if ! confirm "Skip remote upgrade for $node?"; then
            log_error "Cannot proceed with remote upgrade"
            return 1
        fi

        return 0
    fi

    log_success "Packages upgraded on $node"
}

# Wait for node to be ready
wait_for_node_ready() {
    local node="$1"
    local timeout=300
    local elapsed=0

    log_info "Waiting for node $node to be Ready..."

    while [ $elapsed -lt $timeout ]; do
        local status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

        if [ "$status" = "True" ]; then
            log_success "Node $node is Ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done

    echo
    log_error "Timeout waiting for node $node to be Ready"
    return 1
}

# Uncordon node
uncordon_node() {
    local node="$1"

    log_section "Uncordoning Node: $node"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would uncordon node: $node"
        return 0
    fi

    if kubectl uncordon "$node" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Node $node uncordoned"
    else
        log_error "Failed to uncordon node $node"
        return 1
    fi
}

# Verify upgrade
verify_node_upgrade() {
    local node="$1"

    log_section "Verifying Upgrade: $node"

    # Check node version
    local node_version=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
    log_info "Node version: $node_version"

    if [[ "$node_version" == "$TARGET_VERSION" ]]; then
        log_success "Node version matches target version"
    else
        log_warning "Node version ($node_version) does not match target ($TARGET_VERSION)"
    fi

    # Check node status
    local node_status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$node_status" = "True" ]; then
        log_success "Node is Ready"
    else
        log_error "Node is not Ready!"
        return 1
    fi

    # Check if pods are being scheduled
    log_info "Waiting for pods to be scheduled on $node..."
    sleep 15

    local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers 2>/dev/null | wc -l)
    log_info "Pods running on $node: $pod_count"

    kubectl get node "$node" -o wide | tee -a "$LOG_FILE"

    log_success "Verification completed for $node"
}

# Upgrade single node
upgrade_single_node() {
    local node="$1"

    log_section "Upgrading Node: $node"

    # Pre-upgrade checks
    check_node_health "$node" || return 1

    # Cordon node
    cordon_node "$node" || return 1

    # Drain node
    drain_node "$node" || {
        kubectl uncordon "$node"
        return 1
    }

    # Upgrade packages
    upgrade_node_packages "$node" || {
        kubectl uncordon "$node"
        return 1
    }

    # Wait for node to be ready
    wait_for_node_ready "$node" || {
        log_error "Node $node did not become Ready after upgrade"
        return 1
    }

    # Uncordon node
    uncordon_node "$node" || return 1

    # Verify upgrade
    verify_node_upgrade "$node" || return 1

    log_success "Node $node upgraded successfully!"
}

# Main execution
main() {
    log_section "Kubernetes Worker Node Upgrade"
    log_info "Starting upgrade at $(date)"
    log_info "Log file: $LOG_FILE"

    parse_arguments "$@"
    detect_os
    check_prerequisites
    get_worker_nodes

    # Summary before starting
    log_section "Upgrade Summary"
    cat <<EOF | tee -a "$LOG_FILE"
Target Version: $TARGET_VERSION
Nodes to upgrade: ${NODES[*]}
Total nodes: ${#NODES[@]}
Drain timeout: $DRAIN_TIMEOUT
Dry run: $DRY_RUN
EOF

    if ! confirm "Proceed with worker node upgrade?"; then
        log_warning "Upgrade cancelled"
        exit 0
    fi

    # Upgrade nodes one by one
    local success_count=0
    local failed_nodes=()

    for node in "${NODES[@]}"; do
        log_section "Processing Node $((success_count + 1))/${#NODES[@]}: $node"

        if upgrade_single_node "$node"; then
            ((success_count++))
            log_success "Successfully upgraded node: $node"

            # Wait before next node
            if [ ${#NODES[@]} -gt 1 ] && [ $success_count -lt ${#NODES[@]} ]; then
                log_info "Waiting 30 seconds before next node..."
                sleep 30
            fi
        else
            log_error "Failed to upgrade node: $node"
            failed_nodes+=("$node")

            if ! confirm "Continue with remaining nodes?"; then
                break
            fi
        fi
    done

    # Final summary
    log_section "Upgrade Complete"

    cat <<EOF | tee -a "$LOG_FILE"
Worker Node Upgrade Summary
============================
Target Version: $TARGET_VERSION
Total Nodes: ${#NODES[@]}
Successfully Upgraded: $success_count
Failed: ${#failed_nodes[@]}
EOF

    if [ ${#failed_nodes[@]} -gt 0 ]; then
        log_error "Failed nodes: ${failed_nodes[*]}"
        exit 1
    fi

    log_success "All worker nodes upgraded successfully!"

    log_info "Next steps:"
    log_info "1. Verify cluster health: kubectl get nodes"
    log_info "2. Check all pods: kubectl get pods --all-namespaces"
    log_info "3. Run post-upgrade validation: ./k8s-post-upgrade-validation.sh"
}

# Run main function
main "$@"
