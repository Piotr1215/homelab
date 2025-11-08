#!/usr/bin/env bash
# Kubernetes Node Maintenance Script
# Based on official Kubernetes documentation:
# https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
LOG_DIR="${LOG_DIR:-/var/log/k8s-maintenance}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/node-maintenance-${TIMESTAMP}.log"
GRACE_PERIOD="${GRACE_PERIOD:-60}"
TIMEOUT="${TIMEOUT:-300s}"
DELETE_EMPTYDIR_DATA="${DELETE_EMPTYDIR_DATA:-false}"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_error "$1"
    exit 1
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [NODE_NAME]

Safely perform node maintenance operations.

COMMANDS:
    drain       Safely drain a node before maintenance
    cordon      Mark node as unschedulable
    uncordon    Mark node as schedulable
    status      Show node status
    list        List all nodes
    help        Show this help message

OPTIONS (environment variables):
    GRACE_PERIOD=<seconds>      Pod termination grace period (default: 60)
    TIMEOUT=<duration>          Drain timeout (default: 300s)
    DELETE_EMPTYDIR_DATA=true   Delete pods using emptyDir volumes

EXAMPLES:
    $0 drain worker-node-1
    $0 cordon worker-node-2
    $0 uncordon worker-node-1
    GRACE_PERIOD=120 $0 drain worker-node-3

NOTES:
    - Drain respects PodDisruptionBudgets
    - DaemonSets are automatically ignored during drain
    - Pods with local storage require DELETE_EMPTYDIR_DATA=true
    - Always verify node status before and after operations
EOF
    exit 0
}

# Check kubectl availability
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl not found. Please install kubectl."
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error_exit "Cannot connect to Kubernetes cluster"
    fi
}

# Verify node exists
verify_node() {
    local node_name=$1

    if ! kubectl get node "${node_name}" &> /dev/null; then
        error_exit "Node '${node_name}' not found"
    fi

    log_success "Node '${node_name}' found"
}

# Display node information
show_node_info() {
    local node_name=$1

    log_info "Node Information:"
    kubectl get node "${node_name}" -o wide | tee -a "${LOG_FILE}"
    echo ""

    log_info "Node Conditions:"
    kubectl describe node "${node_name}" | grep -A 10 "Conditions:" | tee -a "${LOG_FILE}"
    echo ""

    log_info "Pods on Node:"
    kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName="${node_name}" | tee -a "${LOG_FILE}"
    echo ""
}

# Check Pod Disruption Budgets
check_pdbs() {
    log_info "Checking Pod Disruption Budgets..."

    local pdb_count=$(kubectl get pdb --all-namespaces --no-headers 2>/dev/null | wc -l)

    if [[ ${pdb_count} -gt 0 ]]; then
        log_warning "Found ${pdb_count} PodDisruptionBudget(s) in the cluster"
        log_info "These will be respected during drain operations:"
        kubectl get pdb --all-namespaces | tee -a "${LOG_FILE}"
        echo ""
    else
        log_info "No PodDisruptionBudgets found"
    fi
}

# Cordon node
cordon_node() {
    local node_name=$1

    log_info "Cordoning node '${node_name}'..."

    if kubectl cordon "${node_name}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Node '${node_name}' marked as unschedulable"
    else
        error_exit "Failed to cordon node '${node_name}'"
    fi

    # Verify cordon status
    local status=$(kubectl get node "${node_name}" -o jsonpath='{.spec.unschedulable}')
    if [[ "${status}" == "true" ]]; then
        log_success "Cordon verified - node is unschedulable"
    else
        log_warning "Cordon status unclear"
    fi
}

# Uncordon node
uncordon_node() {
    local node_name=$1

    log_info "Uncordoning node '${node_name}'..."

    if kubectl uncordon "${node_name}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Node '${node_name}' marked as schedulable"
    else
        error_exit "Failed to uncordon node '${node_name}'"
    fi

    # Verify uncordon status
    local status=$(kubectl get node "${node_name}" -o jsonpath='{.spec.unschedulable}')
    if [[ "${status}" == "true" ]]; then
        log_warning "Node still shows as unschedulable"
    else
        log_success "Uncordon verified - node is schedulable"
    fi
}

# Drain node
drain_node() {
    local node_name=$1

    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                    Node Drain Operation                        ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Node: ${BLUE}${node_name}${NC}"
    echo -e "Grace Period: ${BLUE}${GRACE_PERIOD}s${NC}"
    echo -e "Timeout: ${BLUE}${TIMEOUT}${NC}"
    echo -e "Delete EmptyDir Data: ${BLUE}${DELETE_EMPTYDIR_DATA}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Show current pods on node
    log_info "Pods currently running on node:"
    kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName="${node_name}" | tee -a "${LOG_FILE}"
    echo ""

    # Confirm operation
    read -p "Proceed with draining? Type 'yes' to continue: " -r
    if [[ ! $REPLY =~ ^yes$ ]]; then
        log_info "Drain cancelled by user"
        return 0
    fi

    log_info "Starting drain operation for node '${node_name}'..."

    # Build drain command
    local drain_cmd="kubectl drain ${node_name} --ignore-daemonsets --grace-period=${GRACE_PERIOD} --timeout=${TIMEOUT}"

    if [[ "${DELETE_EMPTYDIR_DATA}" == "true" ]]; then
        drain_cmd="${drain_cmd} --delete-emptydir-data"
        log_warning "Will delete pods with emptyDir volumes"
    fi

    # Execute drain
    log_info "Executing: ${drain_cmd}"

    if ${drain_cmd} 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Node '${node_name}' drained successfully"
    else
        log_error "Drain operation encountered issues"
        log_warning "Check the logs for details: ${LOG_FILE}"
        return 1
    fi

    # Verify drain
    echo ""
    log_info "Verifying drain operation..."
    local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="${node_name}" --no-headers 2>/dev/null | grep -v "DaemonSet" | wc -l)

    if [[ ${pod_count} -eq 0 ]]; then
        log_success "All non-DaemonSet pods evicted from node"
    else
        log_warning "Found ${pod_count} non-DaemonSet pod(s) still on node"
        kubectl get pods --all-namespaces --field-selector spec.nodeName="${node_name}" | tee -a "${LOG_FILE}"
    fi
}

# Show node status
show_status() {
    local node_name=$1

    log_info "Node Status for '${node_name}':"
    echo ""

    # Node details
    kubectl get node "${node_name}" -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.conditions[-1].type,\
SCHEDULABLE:.spec.unschedulable,\
VERSION:.status.nodeInfo.kubeletVersion,\
OS:.status.nodeInfo.osImage | tee -a "${LOG_FILE}"

    echo ""

    # Taints
    log_info "Taints:"
    kubectl get node "${node_name}" -o jsonpath='{.spec.taints[*]}' | jq '.' 2>/dev/null || echo "None" | tee -a "${LOG_FILE}"
    echo ""

    # Resource allocation
    log_info "Resource Allocation:"
    kubectl describe node "${node_name}" | grep -A 5 "Allocated resources:" | tee -a "${LOG_FILE}"
    echo ""

    # Running pods
    local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="${node_name}" --no-headers 2>/dev/null | wc -l)
    log_info "Running Pods: ${pod_count}"
}

# List all nodes
list_nodes() {
    log_info "Cluster Nodes:"
    echo ""

    kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.conditions[-1].type,\
SCHEDULABLE:.spec.unschedulable,\
ROLES:.metadata.labels.'node-role\.kubernetes\.io/.*',\
VERSION:.status.nodeInfo.kubeletVersion,\
KERNEL:.status.nodeInfo.kernelVersion | tee -a "${LOG_FILE}"

    echo ""
    log_info "Total nodes: $(kubectl get nodes --no-headers | wc -l)"
}

# Perform pre-drain checks
pre_drain_checks() {
    local node_name=$1

    log_info "Performing pre-drain checks..."

    # Check if node is already cordoned
    local is_cordoned=$(kubectl get node "${node_name}" -o jsonpath='{.spec.unschedulable}')
    if [[ "${is_cordoned}" == "true" ]]; then
        log_info "Node is already cordoned"
    else
        log_info "Node is currently schedulable"
    fi

    # Check for stateful workloads
    log_info "Checking for StatefulSets..."
    local sts_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="${node_name}" -o json | \
        jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="StatefulSet") | .metadata.name' 2>/dev/null)

    if [[ -n "${sts_pods}" ]]; then
        log_warning "Found StatefulSet pods on this node:"
        echo "${sts_pods}" | tee -a "${LOG_FILE}"
        log_warning "Ensure StatefulSet has sufficient replicas before draining"
        echo ""
    fi

    # Check for pods with local storage
    log_info "Checking for pods with emptyDir volumes..."
    local emptydir_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="${node_name}" -o json | \
        jq -r '.items[] | select(.spec.volumes[]?.emptyDir) | .metadata.name' 2>/dev/null)

    if [[ -n "${emptydir_pods}" ]]; then
        log_warning "Found pods with emptyDir volumes:"
        echo "${emptydir_pods}" | tee -a "${LOG_FILE}"
        log_warning "Use DELETE_EMPTYDIR_DATA=true to proceed"
        echo ""
    fi

    log_success "Pre-drain checks completed"
    echo ""
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🔧 Kubernetes Node Maintenance Tool 🔧                    ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local command="${1:-list}"
    local node_name="${2:-}"

    # Check kubectl first
    check_kubectl

    case "${command}" in
        drain)
            if [[ -z "${node_name}" ]]; then
                log_error "Node name required for drain operation"
                usage
            fi
            verify_node "${node_name}"
            show_node_info "${node_name}"
            check_pdbs
            pre_drain_checks "${node_name}"
            drain_node "${node_name}"
            ;;
        cordon)
            if [[ -z "${node_name}" ]]; then
                log_error "Node name required for cordon operation"
                usage
            fi
            verify_node "${node_name}"
            cordon_node "${node_name}"
            show_status "${node_name}"
            ;;
        uncordon)
            if [[ -z "${node_name}" ]]; then
                log_error "Node name required for uncordon operation"
                usage
            fi
            verify_node "${node_name}"
            uncordon_node "${node_name}"
            show_status "${node_name}"
            ;;
        status)
            if [[ -z "${node_name}" ]]; then
                log_error "Node name required for status operation"
                usage
            fi
            verify_node "${node_name}"
            show_status "${node_name}"
            ;;
        list)
            list_nodes
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            ;;
    esac

    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Operation completed${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    log_success "Log file: ${LOG_FILE}"
}

# Run main function
main "$@"
