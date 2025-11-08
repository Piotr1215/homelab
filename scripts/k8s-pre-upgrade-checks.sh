#!/bin/bash
#####################################################################
# Kubernetes Pre-Upgrade Checks Script
#
# This script performs comprehensive pre-upgrade validation checks
# based on official Kubernetes upgrade documentation.
#
# Features:
# - Cluster health verification
# - Version compatibility checks
# - etcd backup with verification
# - Deprecated API detection
# - Component status validation
# - Resource capacity checks
#
# Usage: ./k8s-pre-upgrade-checks.sh <target-version>
# Example: ./k8s-pre-upgrade-checks.sh v1.33.0
#####################################################################

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/kubernetes}"
ETCD_BACKUP_DIR="${ETCD_BACKUP_DIR:-${BACKUP_DIR}/etcd}"
LOG_FILE="${LOG_FILE:-/tmp/k8s-pre-upgrade-$(date +%Y%m%d-%H%M%S).log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Error tracking
ERRORS=0
WARNINGS=0

track_error() {
    ((ERRORS++))
    log_error "$1"
}

track_warning() {
    ((WARNINGS++))
    log_warning "$1"
}

# Prerequisite checks
check_prerequisites() {
    log_section "Checking Prerequisites"

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        track_error "kubectl is not installed or not in PATH"
        return 1
    fi
    log_success "kubectl is installed"

    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        track_error "Cannot connect to Kubernetes cluster. Check KUBECONFIG."
        return 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check if user has admin privileges
    if ! kubectl auth can-i '*' '*' --all-namespaces &> /dev/null; then
        track_warning "Current user may not have cluster-admin privileges"
    else
        log_success "User has cluster-admin privileges"
    fi

    # Create backup directory
    mkdir -p "$BACKUP_DIR" "$ETCD_BACKUP_DIR" 2>/dev/null || track_warning "Cannot create backup directory: $BACKUP_DIR"
}

# Check current cluster version
check_cluster_version() {
    log_section "Checking Cluster Version"

    local current_version=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
    log_info "Current Kubernetes version: ${current_version}"

    # Get component versions
    log_info "Component versions:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion --no-headers | tee -a "$LOG_FILE"

    # Store current version for later comparison
    echo "$current_version" > "$BACKUP_DIR/pre-upgrade-version.txt"
}

# Verify version skew policy
check_version_skew() {
    log_section "Checking Version Skew Policy"

    if [ -z "${TARGET_VERSION:-}" ]; then
        track_warning "No target version specified. Skipping version skew check."
        return 0
    fi

    local current_version=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
    local current_minor=$(echo "$current_version" | cut -d. -f2)
    local target_minor=$(echo "$TARGET_VERSION" | cut -d. -f2)

    log_info "Current minor version: 1.${current_minor}"
    log_info "Target minor version: 1.${target_minor}"

    # Check if trying to skip minor versions
    local version_diff=$((target_minor - current_minor))
    if [ "$version_diff" -gt 1 ]; then
        track_error "Cannot skip minor versions! Must upgrade sequentially (current: 1.${current_minor} -> target: 1.${target_minor})"
        log_error "Upgrade path should be: 1.${current_minor} -> 1.$((current_minor + 1)) -> ... -> 1.${target_minor}"
    elif [ "$version_diff" -eq 1 ]; then
        log_success "Version upgrade path is valid (sequential minor version)"
    elif [ "$version_diff" -eq 0 ]; then
        log_info "Patch version upgrade detected"
    else
        track_error "Target version is older than current version!"
    fi
}

# Check node status
check_nodes() {
    log_section "Checking Node Status"

    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready" || true)

    log_info "Total nodes: $total_nodes"
    log_info "Ready nodes: $ready_nodes"

    if [ "$total_nodes" -ne "$ready_nodes" ]; then
        track_error "Not all nodes are Ready! ($ready_nodes/$total_nodes)"
        kubectl get nodes | tee -a "$LOG_FILE"
    else
        log_success "All nodes are Ready"
    fi

    # Check node conditions
    log_info "Checking node conditions..."
    while IFS= read -r node; do
        local conditions=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')
        if echo "$conditions" | grep -q "MemoryPressure\|DiskPressure\|PIDPressure\|NetworkUnavailable"; then
            track_warning "Node $node has pressure condition: $conditions"
        fi
    done < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
}

# Check system pods
check_system_pods() {
    log_section "Checking System Pods"

    local namespaces="kube-system kube-public kube-node-lease"

    for ns in $namespaces; do
        log_info "Checking pods in namespace: $ns"

        local total_pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        local running_pods=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

        log_info "  Running pods: $running_pods/$total_pods"

        # Check for non-running pods
        local non_running=$(kubectl get pods -n "$ns" --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)
        if [ "$non_running" -gt 0 ]; then
            track_warning "Found $non_running non-running pods in $ns:"
            kubectl get pods -n "$ns" --field-selector=status.phase!=Running,status.phase!=Succeeded | tee -a "$LOG_FILE"
        fi
    done
}

# Check for critical pods
check_critical_components() {
    log_section "Checking Critical Components"

    local critical_components=(
        "kube-system:kube-apiserver"
        "kube-system:kube-controller-manager"
        "kube-system:kube-scheduler"
        "kube-system:etcd"
        "kube-system:kube-proxy"
        "kube-system:coredns"
    )

    for component in "${critical_components[@]}"; do
        local ns=$(echo "$component" | cut -d: -f1)
        local name=$(echo "$component" | cut -d: -f2)

        local pod_count=$(kubectl get pods -n "$ns" -l component="$name" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [ "$pod_count" -eq 0 ]; then
            pod_count=$(kubectl get pods -n "$ns" -l k8s-app="$name" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        fi

        if [ "$pod_count" -gt 0 ]; then
            log_success "$name is running ($pod_count replicas)"
        else
            track_warning "$name pods not found or not running"
        fi
    done
}

# Backup etcd
backup_etcd() {
    log_section "Backing up etcd"

    # Check if etcdctl is available
    if ! command -v etcdctl &> /dev/null; then
        track_warning "etcdctl not found. Manual etcd backup required on control plane node."
        log_info "Run this on control plane node:"
        log_info "  ETCDCTL_API=3 etcdctl snapshot save ${ETCD_BACKUP_DIR}/etcd-snapshot-\$(date +%Y%m%d-%H%M%S).db \\"
        log_info "    --endpoints=https://127.0.0.1:2379 \\"
        log_info "    --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
        log_info "    --cert=/etc/kubernetes/pki/etcd/server.crt \\"
        log_info "    --key=/etc/kubernetes/pki/etcd/server.key"
        return 0
    fi

    local snapshot_file="${ETCD_BACKUP_DIR}/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"

    log_info "Creating etcd snapshot: $snapshot_file"

    # Attempt automated backup (requires running on control plane with proper certs)
    if ETCDCTL_API=3 etcdctl snapshot save "$snapshot_file" \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key 2>&1 | tee -a "$LOG_FILE"; then

        log_success "etcd snapshot created: $snapshot_file"

        # Verify snapshot
        if ETCDCTL_API=3 etcdctl snapshot status "$snapshot_file" -w table | tee -a "$LOG_FILE"; then
            log_success "etcd snapshot verified"
        else
            track_error "etcd snapshot verification failed"
        fi
    else
        track_warning "Automated etcd backup failed. Manual backup required."
    fi
}

# Backup cluster resources
backup_cluster_resources() {
    log_section "Backing up Cluster Resources"

    local resource_backup_dir="${BACKUP_DIR}/resources-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$resource_backup_dir"

    log_info "Backing up cluster resources to: $resource_backup_dir"

    # Backup cluster-wide resources
    local resources=(
        "nodes"
        "namespaces"
        "persistentvolumes"
        "storageclasses"
        "clusterroles"
        "clusterrolebindings"
        "customresourcedefinitions"
    )

    for resource in "${resources[@]}"; do
        log_info "Backing up $resource..."
        kubectl get "$resource" -o yaml > "$resource_backup_dir/${resource}.yaml" 2>/dev/null || track_warning "Failed to backup $resource"
    done

    # Backup all namespaced resources
    log_info "Backing up namespaced resources..."
    kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | while read -r ns; do
        mkdir -p "$resource_backup_dir/namespaces/$ns"
        kubectl get all,configmap,secret,pvc,ingress -n "$ns" -o yaml > "$resource_backup_dir/namespaces/$ns/all-resources.yaml" 2>/dev/null || true
    done

    log_success "Cluster resources backed up to: $resource_backup_dir"
}

# Check for deprecated APIs
check_deprecated_apis() {
    log_section "Checking for Deprecated APIs"

    if command -v pluto &> /dev/null; then
        log_info "Running Pluto to detect deprecated APIs..."
        pluto detect-all-in-cluster --target-versions "k8s=${TARGET_VERSION:-v1.33.0}" | tee -a "$LOG_FILE"
    else
        track_warning "Pluto not installed. Cannot automatically detect deprecated APIs."
        log_info "Install Pluto: https://github.com/FairwindsOps/pluto"
        log_info "Or use: kubectl-convert to manually check API versions"
    fi

    # Basic manual check for common deprecated APIs
    log_info "Performing basic deprecated API check..."

    local deprecated_found=false

    # Check for common deprecated resources
    if kubectl get deploy,sts,ds,rs -A -o json 2>/dev/null | grep -q "apiVersion.*apps/v1beta"; then
        track_warning "Found resources using deprecated apps/v1beta* API"
        deprecated_found=true
    fi

    if kubectl get ingress -A -o json 2>/dev/null | grep -q "apiVersion.*extensions/v1beta1"; then
        track_warning "Found Ingress resources using deprecated extensions/v1beta1 API"
        deprecated_found=true
    fi

    if [ "$deprecated_found" = false ]; then
        log_success "No obviously deprecated APIs detected"
    fi
}

# Check resource capacity
check_resource_capacity() {
    log_section "Checking Resource Capacity"

    log_info "Node resource utilization:"
    kubectl top nodes 2>/dev/null || track_warning "Metrics server not available. Cannot check resource usage."

    log_info "\nPod resource requests/limits:"
    kubectl describe nodes | grep -A 5 "Allocated resources:" | tee -a "$LOG_FILE"

    # Check for resource pressure
    local nodes_with_pressure=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") | select(.status=="True")) | .metadata.name' 2>/dev/null)

    if [ -n "$nodes_with_pressure" ]; then
        track_warning "Nodes with resource pressure detected:"
        echo "$nodes_with_pressure" | tee -a "$LOG_FILE"
    else
        log_success "No resource pressure detected"
    fi
}

# Check persistent volumes
check_persistent_volumes() {
    log_section "Checking Persistent Volumes"

    local total_pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    local bound_pvs=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Bound" || echo "0")

    log_info "Total PVs: $total_pvs"
    log_info "Bound PVs: $bound_pvs"

    if [ "$total_pvs" -gt 0 ]; then
        kubectl get pv -o wide | tee -a "$LOG_FILE"

        # Check for PVs with issues
        local failed_pvs=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Failed" || echo "0")
        if [ "$failed_pvs" -gt 0 ]; then
            track_warning "Found $failed_pvs failed PVs"
        fi
    else
        log_info "No persistent volumes in cluster"
    fi
}

# Check custom resources
check_custom_resources() {
    log_section "Checking Custom Resource Definitions"

    local crd_count=$(kubectl get crd --no-headers 2>/dev/null | wc -l)
    log_info "Total CRDs: $crd_count"

    if [ "$crd_count" -gt 0 ]; then
        log_info "Installed CRDs:"
        kubectl get crd -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp --no-headers | tee -a "$LOG_FILE"

        # Backup CRDs
        log_info "Backing up CRDs..."
        kubectl get crd -o yaml > "${BACKUP_DIR}/crds-$(date +%Y%m%d-%H%M%S).yaml"
        log_success "CRDs backed up"
    fi
}

# Check swap status (Kubernetes requires swap disabled)
check_swap_status() {
    log_section "Checking Swap Status"

    if swapon -s | grep -q "/"; then
        track_error "Swap is enabled! Kubernetes requires swap to be disabled."
        swapon -s | tee -a "$LOG_FILE"
    else
        log_success "Swap is disabled"
    fi
}

# Check kubeadm configuration
check_kubeadm_config() {
    log_section "Checking kubeadm Configuration"

    if command -v kubeadm &> /dev/null; then
        log_info "kubeadm version: $(kubeadm version -o short)"

        # Get upgrade plan if target version specified
        if [ -n "${TARGET_VERSION:-}" ]; then
            log_info "Running kubeadm upgrade plan..."
            if sudo kubeadm upgrade plan 2>&1 | tee -a "$LOG_FILE"; then
                log_success "kubeadm upgrade plan completed"
            else
                track_warning "kubeadm upgrade plan failed or returned warnings"
            fi
        fi
    else
        track_warning "kubeadm not found. This check only applies to kubeadm clusters."
    fi
}

# Generate upgrade checklist
generate_checklist() {
    log_section "Pre-Upgrade Checklist Summary"

    local checklist_file="${BACKUP_DIR}/pre-upgrade-checklist-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$checklist_file" <<EOF
Kubernetes Pre-Upgrade Checklist
Generated: $(date)
Target Version: ${TARGET_VERSION:-Not specified}
Current Version: $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')

Pre-Upgrade Checks:
[ ] Cluster health verified
[ ] All nodes are Ready
[ ] System pods are running
[ ] etcd backup completed and verified
[ ] Cluster resources backed up
[ ] Deprecated APIs checked and migrated
[ ] Resource capacity verified
[ ] Persistent volumes are healthy
[ ] Custom resources backed up
[ ] Swap is disabled on all nodes
[ ] Version skew policy validated
[ ] kubeadm upgrade plan reviewed

Critical Backups Location:
- Backup directory: ${BACKUP_DIR}
- etcd snapshots: ${ETCD_BACKUP_DIR}
- Resource backups: ${BACKUP_DIR}/resources-*
- Log file: ${LOG_FILE}

Manual Steps Required:
1. Review the upgrade plan: sudo kubeadm upgrade plan
2. Check release notes: https://kubernetes.io/docs/setup/release/notes/
3. Ensure all operators and controllers are compatible with target version
4. Plan maintenance window
5. Notify stakeholders

Upgrade Order:
1. Upgrade control plane nodes (one at a time)
   - First control plane: kubeadm upgrade apply ${TARGET_VERSION:-vX.Y.Z}
   - Other control planes: kubeadm upgrade node
2. Upgrade worker nodes (one or few at a time)
3. Verify cluster health after each node

Errors: ${ERRORS}
Warnings: ${WARNINGS}
EOF

    cat "$checklist_file" | tee -a "$LOG_FILE"
    log_success "Checklist saved to: $checklist_file"
}

# Main execution
main() {
    local target_version="${1:-}"

    if [ -n "$target_version" ]; then
        TARGET_VERSION="$target_version"
        log_info "Target version: $TARGET_VERSION"
    fi

    log_section "Kubernetes Pre-Upgrade Checks"
    log_info "Starting pre-upgrade checks at $(date)"
    log_info "Log file: $LOG_FILE"

    # Run all checks
    check_prerequisites || exit 1
    check_cluster_version
    check_version_skew
    check_nodes
    check_system_pods
    check_critical_components
    check_swap_status
    backup_etcd
    backup_cluster_resources
    check_deprecated_apis
    check_resource_capacity
    check_persistent_volumes
    check_custom_resources
    check_kubeadm_config

    # Generate summary
    generate_checklist

    # Final summary
    log_section "Pre-Upgrade Checks Complete"

    if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        log_success "All checks passed! Cluster is ready for upgrade."
        exit 0
    elif [ "$ERRORS" -eq 0 ]; then
        log_warning "Checks completed with $WARNINGS warnings. Review before proceeding."
        exit 0
    else
        log_error "Checks completed with $ERRORS errors and $WARNINGS warnings."
        log_error "Please resolve errors before upgrading!"
        exit 1
    fi
}

# Run main function
main "$@"
