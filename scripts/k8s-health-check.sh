#!/usr/bin/env bash
# Kubernetes Cluster Health Check Script
# Based on official Kubernetes documentation:
# https://kubernetes.io/docs/tasks/debug/debug-cluster/
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
LOG_DIR="${LOG_DIR:-/var/log/k8s-maintenance}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/health-check-${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/health-report-${TIMESTAMP}.txt"
CRITICAL_NAMESPACES="${CRITICAL_NAMESPACES:-kube-system,kube-public,kube-node-lease}"
CHECK_METRICS="${CHECK_METRICS:-true}"
VERBOSE="${VERBOSE:-false}"

# Health status tracking
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*" | tee -a "${LOG_FILE}"
    ((PASSED_CHECKS++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
    ((WARNING_CHECKS++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" | tee -a "${LOG_FILE}"
    ((FAILED_CHECKS++))
}

log_check() {
    echo -e "${CYAN}[CHECK]${NC} $*" | tee -a "${LOG_FILE}"
    ((TOTAL_CHECKS++))
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Comprehensive Kubernetes cluster health validation.

OPTIONS:
    -v, --verbose           Show detailed output
    -m, --no-metrics        Skip metrics server checks
    -n, --namespaces        Comma-separated list of critical namespaces
    -h, --help              Show this help message

EXAMPLES:
    $0                      # Run all health checks
    $0 -v                   # Verbose output
    $0 -n "default,app"     # Check specific namespaces

CHECKS PERFORMED:
    - Cluster connectivity and API server
    - Node health and readiness
    - Control plane component status
    - System pod health
    - Resource availability
    - Network connectivity
    - Storage provisioning
    - Certificate expiration
    - Metrics and monitoring
EOF
    exit 0
}

# Check cluster connectivity
check_cluster_connectivity() {
    log_check "Checking cluster connectivity..."

    if kubectl cluster-info &> /dev/null; then
        local api_server=$(kubectl cluster-info | grep "control plane" | awk '{print $NF}')
        log_success "Cluster API server accessible: ${api_server}"
    else
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # Get cluster version
    local version=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo "unknown")
    log_info "Kubernetes version: ${version}"
}

# Check node health
check_node_health() {
    log_check "Checking node health..."

    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    local not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc " Ready " || true)

    log_info "Total nodes: ${total_nodes}"
    log_info "Ready nodes: ${ready_nodes}"

    if [[ ${not_ready} -gt 0 ]]; then
        log_error "Found ${not_ready} node(s) not in Ready state"
        kubectl get nodes | grep -v " Ready " | tee -a "${LOG_FILE}"
        return 1
    else
        log_success "All nodes are in Ready state"
    fi

    # Check node conditions
    log_info "Checking node conditions..."
    local unhealthy_nodes=$(kubectl get nodes -o json | jq -r '
        .items[] |
        select(.status.conditions[] |
        select(.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") |
        .status == "True") |
        .metadata.name' 2>/dev/null)

    if [[ -n "${unhealthy_nodes}" ]]; then
        log_warning "Nodes with resource pressure:"
        echo "${unhealthy_nodes}" | tee -a "${LOG_FILE}"
    else
        log_success "No resource pressure detected on nodes"
    fi
}

# Check control plane components
check_control_plane() {
    log_check "Checking control plane components..."

    local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")
    local all_healthy=true

    for component in "${components[@]}"; do
        local pod_status=$(kubectl get pods -n kube-system -l component="${component}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "${pod_status}" == "Running" ]]; then
            log_success "${component}: Running"
        else
            log_error "${component}: ${pod_status}"
            all_healthy=false
        fi
    done

    if [[ "${all_healthy}" == "true" ]]; then
        log_success "All control plane components healthy"
    else
        log_error "Some control plane components are not healthy"
        return 1
    fi
}

# Check system pods
check_system_pods() {
    log_check "Checking system pods in kube-system namespace..."

    # Get pod status
    local total_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)
    local running_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Running" || true)
    local failed_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -Ec "Error|CrashLoopBackOff|ImagePullBackOff" || true)

    log_info "Total system pods: ${total_pods}"
    log_info "Running pods: ${running_pods}"

    if [[ ${failed_pods} -gt 0 ]]; then
        log_error "Found ${failed_pods} failed system pod(s)"
        kubectl get pods -n kube-system | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" | tee -a "${LOG_FILE}"
        return 1
    else
        log_success "All system pods are healthy"
    fi

    # Check for pods with high restart counts
    local high_restarts=$(kubectl get pods -n kube-system -o json | jq -r '
        .items[] |
        select(.status.containerStatuses[]?.restartCount > 5) |
        .metadata.name + " (restarts: " + (.status.containerStatuses[0].restartCount | tostring) + ")"' 2>/dev/null)

    if [[ -n "${high_restarts}" ]]; then
        log_warning "Pods with high restart counts:"
        echo "${high_restarts}" | tee -a "${LOG_FILE}"
    fi
}

# Check critical namespace pods
check_critical_namespaces() {
    log_check "Checking critical namespaces: ${CRITICAL_NAMESPACES}..."

    IFS=',' read -ra NAMESPACES <<< "${CRITICAL_NAMESPACES}"

    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "${ns}" &> /dev/null; then
            local failed=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
                grep -Ec "Error|CrashLoopBackOff|ImagePullBackOff" || true)

            if [[ ${failed} -gt 0 ]]; then
                log_warning "Namespace ${ns} has ${failed} failed pod(s)"
            else
                log_success "Namespace ${ns}: All pods healthy"
            fi
        fi
    done
}

# Check resource availability
check_resources() {
    log_check "Checking cluster resource availability..."

    # Check if metrics-server is available
    if kubectl top nodes &> /dev/null; then
        log_info "Node resource usage:"
        kubectl top nodes | tee -a "${LOG_FILE}"

        # Check for high resource usage
        local high_cpu=$(kubectl top nodes --no-headers 2>/dev/null | awk '{gsub("%","",$3); if($3>80) print $1" CPU: "$3"%"}')
        local high_mem=$(kubectl top nodes --no-headers 2>/dev/null | awk '{gsub("%","",$5); if($5>80) print $1" Memory: "$5"%"}')

        if [[ -n "${high_cpu}" ]]; then
            log_warning "High CPU usage detected:"
            echo "${high_cpu}" | tee -a "${LOG_FILE}"
        fi

        if [[ -n "${high_mem}" ]]; then
            log_warning "High memory usage detected:"
            echo "${high_mem}" | tee -a "${LOG_FILE}"
        fi

        if [[ -z "${high_cpu}" && -z "${high_mem}" ]]; then
            log_success "Resource usage is within normal limits"
        fi
    else
        log_warning "Cannot retrieve metrics (metrics-server may not be installed)"
    fi
}

# Check persistent volumes
check_storage() {
    log_check "Checking persistent volume status..."

    local pv_total=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    local pv_failed=$(kubectl get pv --no-headers 2>/dev/null | grep -Ec "Failed|Released" || true)

    log_info "Total PVs: ${pv_total}"

    if [[ ${pv_failed} -gt 0 ]]; then
        log_warning "Found ${pv_failed} PV(s) in Failed/Released state"
        kubectl get pv | grep -E "Failed|Released" | tee -a "${LOG_FILE}"
    else
        if [[ ${pv_total} -gt 0 ]]; then
            log_success "All PVs are healthy"
        else
            log_info "No PVs found in cluster"
        fi
    fi

    # Check PVCs
    local pvc_pending=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [[ ${pvc_pending} -gt 0 ]]; then
        log_warning "Found ${pvc_pending} PVC(s) in Pending state"
        kubectl get pvc --all-namespaces | grep "Pending" | tee -a "${LOG_FILE}"
    fi
}

# Check network connectivity
check_network() {
    log_check "Checking network components..."

    # Check CoreDNS
    local coredns_status=$(kubectl get deployment -n kube-system coredns \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "NotFound")

    if [[ "${coredns_status}" == "True" ]]; then
        log_success "CoreDNS is available"
    else
        log_error "CoreDNS is not available"
    fi

    # Check kube-proxy
    local proxy_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
    local proxy_running=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ ${proxy_pods} -eq ${proxy_running} && ${proxy_pods} -gt 0 ]]; then
        log_success "kube-proxy is running on all nodes (${proxy_pods}/${proxy_running})"
    else
        log_warning "kube-proxy status: ${proxy_running}/${proxy_pods} pods running"
    fi

    # Check services
    local services_total=$(kubectl get svc --all-namespaces --no-headers 2>/dev/null | wc -l)
    log_info "Total services: ${services_total}"

    # Check for services with no endpoints
    local svc_no_endpoints=$(kubectl get endpoints --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.subsets | length == 0) |
        .metadata.namespace + "/" + .metadata.name' || true)

    if [[ -n "${svc_no_endpoints}" ]]; then
        log_warning "Services with no endpoints:"
        echo "${svc_no_endpoints}" | tee -a "${LOG_FILE}"
    else
        log_success "All services have endpoints"
    fi
}

# Check certificates
check_certificates() {
    log_check "Checking certificate expiration..."

    if command -v kubeadm &> /dev/null && [[ -f /etc/kubernetes/admin.conf ]]; then
        local cert_output=$(kubeadm certs check-expiration 2>/dev/null || echo "")

        if [[ -n "${cert_output}" ]]; then
            # Check for certificates expiring soon (< 30 days)
            local expiring_soon=$(echo "${cert_output}" | grep -E "[0-9]+d" | awk '{gsub("d","",$5); if($5<30) print}')

            if [[ -n "${expiring_soon}" ]]; then
                log_warning "Certificates expiring within 30 days:"
                echo "${expiring_soon}" | tee -a "${LOG_FILE}"
            else
                log_success "All certificates valid for at least 30 days"
            fi
        else
            log_info "Certificate check not available (not a control plane node or kubeadm not used)"
        fi
    else
        log_info "Skipping certificate check (kubeadm not available)"
    fi
}

# Check events for errors
check_events() {
    log_check "Checking recent cluster events..."

    local warning_events=$(kubectl get events --all-namespaces --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -10)

    if [[ -n "${warning_events}" ]]; then
        log_warning "Recent warning events (last 10):"
        echo "${warning_events}" | tee -a "${LOG_FILE}"
    else
        log_success "No recent warning events"
    fi
}

# Check image pull errors
check_images() {
    log_check "Checking for image pull errors..."

    local image_errors=$(kubectl get events --all-namespaces --field-selector reason=Failed \
        2>/dev/null | grep -i "image" || true)

    if [[ -n "${image_errors}" ]]; then
        log_warning "Image pull errors detected:"
        echo "${image_errors}" | tee -a "${LOG_FILE}"
    else
        log_success "No image pull errors detected"
    fi
}

# Check deployment health
check_deployments() {
    log_check "Checking deployment health..."

    local unhealthy_deploys=$(kubectl get deployments --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.replicas != .status.availableReplicas) |
        .metadata.namespace + "/" + .metadata.name +
        " (desired: " + (.spec.replicas|tostring) +
        ", available: " + (.status.availableReplicas|tostring) + ")"')

    if [[ -n "${unhealthy_deploys}" ]]; then
        log_warning "Deployments not at desired replica count:"
        echo "${unhealthy_deploys}" | tee -a "${LOG_FILE}"
    else
        log_success "All deployments at desired replica count"
    fi
}

# Generate summary report
generate_report() {
    log_info "Generating health check report..."

    cat > "${REPORT_FILE}" <<EOF
Kubernetes Cluster Health Check Report
Generated: ${TIMESTAMP}
═══════════════════════════════════════════════════════════════

SUMMARY
-------
Total Checks:    ${TOTAL_CHECKS}
Passed:          ${PASSED_CHECKS}
Failed:          ${FAILED_CHECKS}
Warnings:        ${WARNING_CHECKS}

OVERALL STATUS
--------------
EOF

    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        echo "Status: HEALTHY ✓" >> "${REPORT_FILE}"
    elif [[ ${FAILED_CHECKS} -le 2 ]]; then
        echo "Status: DEGRADED ⚠" >> "${REPORT_FILE}"
    else
        echo "Status: UNHEALTHY ✗" >> "${REPORT_FILE}"
    fi

    cat >> "${REPORT_FILE}" <<EOF

CLUSTER INFORMATION
-------------------
API Server:      $(kubectl cluster-info 2>/dev/null | grep "control plane" | awk '{print $NF}' || echo "N/A")
Kubernetes:      $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo "N/A")
Total Nodes:     $(kubectl get nodes --no-headers 2>/dev/null | wc -l)
Total Namespaces: $(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
Total Pods:      $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)

For detailed logs, see: ${LOG_FILE}
═══════════════════════════════════════════════════════════════
EOF

    cat "${REPORT_FILE}" | tee -a "${LOG_FILE}"
    log_success "Report saved to: ${REPORT_FILE}"
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🏥 Kubernetes Cluster Health Check 🏥                     ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_info "Starting comprehensive cluster health check..."
    echo ""

    # Run all health checks
    check_cluster_connectivity
    echo ""

    check_node_health
    echo ""

    check_control_plane
    echo ""

    check_system_pods
    echo ""

    check_critical_namespaces
    echo ""

    check_resources
    echo ""

    check_storage
    echo ""

    check_network
    echo ""

    check_certificates
    echo ""

    check_deployments
    echo ""

    check_events
    echo ""

    check_images
    echo ""

    # Generate report
    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    generate_report
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"

    # Exit with appropriate status
    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -m|--no-metrics)
            CHECK_METRICS=false
            shift
            ;;
        -n|--namespaces)
            CRITICAL_NAMESPACES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Run main function
main "$@"
