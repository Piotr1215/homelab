#!/usr/bin/env bash
#
# k8s-quick-diagnostics.sh - Kubernetes Quick Diagnostics
# Based on official Kubernetes documentation:
# - https://kubernetes.io/docs/tasks/debug/
# - Quick cluster health checks and diagnostics
#
# This script provides rapid cluster health assessment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

VERSION="1.0.0"

# Counters for health assessment
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

print_header() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}>>> $1${NC}"
    echo -e "${CYAN}$(printf '%.0s-' {1..78})${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    ((PASSED_CHECKS++))
    ((TOTAL_CHECKS++))
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    ((FAILED_CHECKS++))
    ((TOTAL_CHECKS++))
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    ((WARNING_CHECKS++))
    ((TOTAL_CHECKS++))
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

usage() {
    cat << EOF
Kubernetes Quick Diagnostics v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
    -n, --namespace <ns>    Focus on specific namespace
    -v, --verbose           Verbose output
    -q, --quiet             Minimal output (only issues)
    -o, --output <file>     Save report to file
    -h, --help              Show this help message

Examples:
    # Quick cluster health check
    $(basename "$0")

    # Check specific namespace
    $(basename "$0") -n production

    # Save report to file
    $(basename "$0") -o cluster-report.txt

EOF
    exit 0
}

check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        print_error "Unable to connect to Kubernetes cluster"
        exit 1
    fi
}

check_cluster_connectivity() {
    print_section "Cluster Connectivity"

    if kubectl cluster-info &> /dev/null; then
        print_success "Cluster is reachable"
        kubectl cluster-info | head -n 2
    else
        print_error "Cannot connect to cluster"
        return 1
    fi
}

check_node_health() {
    print_section "Node Health"

    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    local notready_nodes=$((total_nodes - ready_nodes))

    echo "Total Nodes: $total_nodes"
    echo "Ready Nodes: $ready_nodes"

    if [ "$notready_nodes" -gt 0 ]; then
        print_error "NotReady Nodes: $notready_nodes"
        kubectl get nodes | grep -v " Ready "
    else
        print_success "All nodes are Ready"
    fi

    # Check node conditions
    echo ""
    print_info "Node Conditions:"
    kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status'

    # Check for pressure conditions
    local memory_pressure=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="MemoryPressure" and .status=="True")) | .metadata.name' | wc -l)
    local disk_pressure=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="DiskPressure" and .status=="True")) | .metadata.name' | wc -l)
    local pid_pressure=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="PIDPressure" and .status=="True")) | .metadata.name' | wc -l)

    if [ "$memory_pressure" -gt 0 ]; then
        print_warning "Nodes under memory pressure: $memory_pressure"
    fi

    if [ "$disk_pressure" -gt 0 ]; then
        print_warning "Nodes under disk pressure: $disk_pressure"
    fi

    if [ "$pid_pressure" -gt 0 ]; then
        print_warning "Nodes under PID pressure: $pid_pressure"
    fi

    if [ "$memory_pressure" -eq 0 ] && [ "$disk_pressure" -eq 0 ] && [ "$pid_pressure" -eq 0 ]; then
        print_success "No resource pressure detected on nodes"
    fi
}

check_system_pods() {
    print_section "System Components"

    print_info "Control Plane Pods (kube-system):"

    local system_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null)
    local total_system=$(echo "$system_pods" | wc -l)
    local running_system=$(echo "$system_pods" | grep -c "Running" || true)
    local failed_system=$(echo "$system_pods" | grep -v "Running" | grep -v "Completed" | wc -l)

    echo "Total system pods: $total_system"
    echo "Running: $running_system"

    if [ "$failed_system" -gt 0 ]; then
        print_error "Failed/Pending system pods: $failed_system"
        kubectl get pods -n kube-system | grep -v "Running" | grep -v "Completed" | grep -v "NAME"
    else
        print_success "All system pods are running"
    fi

    # Check critical components
    echo ""
    print_info "Checking critical components:"

    local critical_components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd" "coredns")
    for component in "${critical_components[@]}"; do
        local pod_count=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "$component" || true)
        if [ "$pod_count" -gt 0 ]; then
            local running_count=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep "$component" | grep -c "Running" || true)
            if [ "$running_count" -eq "$pod_count" ]; then
                print_success "$component: $running_count/$pod_count running"
            else
                print_error "$component: $running_count/$pod_count running"
            fi
        fi
    done
}

check_pod_status() {
    local namespace="${1:-}"

    print_section "Pod Status${namespace:+ in $namespace}"

    local ns_flag=""
    [ -n "$namespace" ] && ns_flag="-n $namespace" || ns_flag="--all-namespaces"

    local total_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | wc -l)
    local running_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c "Running" || true)
    local pending_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c "Pending" || true)
    local failed_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c -E "Error|CrashLoopBackOff|ImagePullBackOff" || true)
    local completed_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c "Completed" || true)

    echo "Total Pods: $total_pods"
    echo "Running: $running_pods"
    echo "Pending: $pending_pods"
    echo "Failed: $failed_pods"
    echo "Completed: $completed_pods"

    if [ "$failed_pods" -gt 0 ]; then
        print_error "Failed pods detected: $failed_pods"
        echo ""
        kubectl get pods $ns_flag | grep -E "Error|CrashLoopBackOff|ImagePullBackOff|Failed" | head -n 10
    else
        print_success "No failed pods"
    fi

    if [ "$pending_pods" -gt 0 ]; then
        print_warning "Pending pods: $pending_pods"
        echo ""
        kubectl get pods $ns_flag --field-selector=status.phase=Pending | head -n 10
    fi

    # Check for pods with restarts
    echo ""
    print_info "Pods with restarts (top 10):"
    kubectl get pods $ns_flag --sort-by='.status.containerStatuses[0].restartCount' 2>/dev/null | tail -n 11 | head -n 10 || print_info "No restart data available"
}

check_deployments() {
    local namespace="${1:-}"

    print_section "Deployment Status${namespace:+ in $namespace}"

    local ns_flag=""
    [ -n "$namespace" ] && ns_flag="-n $namespace" || ns_flag="--all-namespaces"

    local deployments=$(kubectl get deployments $ns_flag --no-headers 2>/dev/null)

    if [ -z "$deployments" ]; then
        print_info "No deployments found"
        return
    fi

    local total_deployments=$(echo "$deployments" | wc -l)
    echo "Total Deployments: $total_deployments"
    echo ""

    # Check for deployments with unavailable replicas
    local unhealthy=0
    while IFS= read -r line; do
        local desired=$(echo "$line" | awk '{print $3}')
        local ready=$(echo "$line" | awk '{print $4}')

        if [ "$desired" != "$ready" ]; then
            echo "$line"
            ((unhealthy++))
        fi
    done <<< "$deployments"

    if [ "$unhealthy" -gt 0 ]; then
        print_warning "Deployments with unavailable replicas: $unhealthy"
    else
        print_success "All deployments have desired replicas available"
    fi
}

check_pv_pvc() {
    print_section "Storage (PV/PVC)"

    # Check PVs
    local total_pv=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    local available_pv=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Available" || true)
    local bound_pv=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Bound" || true)
    local failed_pv=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Failed" || true)

    echo "Persistent Volumes:"
    echo "  Total: $total_pv"
    echo "  Bound: $bound_pv"
    echo "  Available: $available_pv"
    echo "  Failed: $failed_pv"

    if [ "$failed_pv" -gt 0 ]; then
        print_error "Failed PVs detected: $failed_pv"
    fi

    # Check PVCs
    echo ""
    local total_pvc=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
    local bound_pvc=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Bound" || true)
    local pending_pvc=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Pending" || true)

    echo "Persistent Volume Claims:"
    echo "  Total: $total_pvc"
    echo "  Bound: $bound_pvc"
    echo "  Pending: $pending_pvc"

    if [ "$pending_pvc" -gt 0 ]; then
        print_warning "Pending PVCs: $pending_pvc"
        kubectl get pvc --all-namespaces | grep "Pending"
    else
        if [ "$total_pvc" -gt 0 ]; then
            print_success "All PVCs are bound"
        else
            print_info "No PVCs found"
        fi
    fi
}

check_recent_events() {
    local namespace="${1:-}"

    print_section "Recent Events${namespace:+ in $namespace}"

    local ns_flag=""
    [ -n "$namespace" ] && ns_flag="-n $namespace" || ns_flag="--all-namespaces"

    print_info "Recent Warning/Error events (last 20):"
    kubectl get events $ns_flag --sort-by='.lastTimestamp' --field-selector type!=Normal 2>/dev/null | tail -n 20 || print_info "No warning/error events found"

    local warning_count=$(kubectl get events $ns_flag --field-selector type=Warning 2>/dev/null | wc -l)
    if [ "$warning_count" -gt 1 ]; then  # -gt 1 because of header line
        print_warning "Total warning events: $((warning_count - 1))"
    else
        print_success "No warning events in recent history"
    fi
}

check_resource_usage() {
    print_section "Resource Usage"

    # Check if metrics-server is available
    if ! kubectl top nodes &> /dev/null; then
        print_warning "metrics-server not available - cannot show resource usage"
        print_info "Install metrics-server to enable resource monitoring"
        return
    fi

    print_info "Node Resource Usage:"
    kubectl top nodes

    # Check for high resource usage
    echo ""
    kubectl top nodes --no-headers | while read line; do
        local node=$(echo "$line" | awk '{print $1}')
        local cpu_percent=$(echo "$line" | awk '{print $3}' | tr -d '%')
        local mem_percent=$(echo "$line" | awk '{print $5}' | tr -d '%')

        if [ "$cpu_percent" -gt 80 ]; then
            print_warning "Node $node: High CPU usage (${cpu_percent}%)"
        fi

        if [ "$mem_percent" -gt 80 ]; then
            print_warning "Node $node: High memory usage (${mem_percent}%)"
        fi
    done

    echo ""
    print_info "Top 5 CPU consumers:"
    kubectl top pods --all-namespaces --sort-by=cpu 2>/dev/null | head -n 6

    echo ""
    print_info "Top 5 Memory consumers:"
    kubectl top pods --all-namespaces --sort-by=memory 2>/dev/null | head -n 6
}

check_services() {
    local namespace="${1:-}"

    print_section "Service Status${namespace:+ in $namespace}"

    local ns_flag=""
    [ -n "$namespace" ] && ns_flag="-n $namespace" || ns_flag="--all-namespaces"

    local total_services=$(kubectl get services $ns_flag --no-headers 2>/dev/null | wc -l)
    echo "Total Services: $total_services"

    if [ "$total_services" -gt 0 ]; then
        print_success "Found $total_services services"

        # Check for services without endpoints
        echo ""
        print_info "Checking for services without endpoints..."
        local services_without_endpoints=0

        kubectl get services $ns_flag -o json | jq -r '.items[] | "\(.metadata.namespace):\(.metadata.name)"' | while IFS=: read -r ns svc; do
            local endpoints=$(kubectl get endpoints "$svc" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
            if [ -z "$endpoints" ]; then
                echo "  $ns/$svc has no endpoints"
                ((services_without_endpoints++))
            fi
        done

        if [ "$services_without_endpoints" -eq 0 ]; then
            print_success "All services have endpoints"
        fi
    fi
}

check_certificate_expiry() {
    print_section "Certificate Status"

    # Check if cert-manager is installed
    if kubectl get namespace cert-manager &> /dev/null; then
        print_info "cert-manager detected"

        local certs=$(kubectl get certificates --all-namespaces --no-headers 2>/dev/null | wc -l)
        local ready_certs=$(kubectl get certificates --all-namespaces --no-headers 2>/dev/null | grep -c "True" || true)

        echo "Certificates managed by cert-manager:"
        echo "  Total: $certs"
        echo "  Ready: $ready_certs"

        if [ "$certs" -gt "$ready_certs" ]; then
            print_warning "Some certificates are not ready:"
            kubectl get certificates --all-namespaces | grep -v "True"
        else
            print_success "All certificates are ready"
        fi
    else
        print_info "cert-manager not installed - skipping certificate check"
    fi
}

generate_summary() {
    print_header "Diagnostic Summary"

    echo ""
    echo "Total Checks: $TOTAL_CHECKS"
    echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
    echo -e "${YELLOW}Warnings: $WARNING_CHECKS${NC}"
    echo -e "${RED}Failed: $FAILED_CHECKS${NC}"

    echo ""
    local health_percentage=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))

    if [ "$health_percentage" -ge 90 ]; then
        print_success "Cluster Health: ${health_percentage}% - EXCELLENT"
    elif [ "$health_percentage" -ge 75 ]; then
        print_info "Cluster Health: ${health_percentage}% - GOOD"
    elif [ "$health_percentage" -ge 50 ]; then
        print_warning "Cluster Health: ${health_percentage}% - NEEDS ATTENTION"
    else
        print_error "Cluster Health: ${health_percentage}% - CRITICAL"
    fi

    echo ""
    print_info "Report generated at: $(date)"
}

# Main diagnostic function
run_diagnostics() {
    local namespace="${1:-}"

    print_header "Kubernetes Quick Diagnostics"
    echo "Timestamp: $(date)"
    echo "Cluster: $(kubectl config current-context)"
    [ -n "$namespace" ] && echo "Namespace: $namespace"
    echo ""

    check_cluster_connectivity
    check_node_health
    check_system_pods
    check_pod_status "$namespace"
    check_deployments "$namespace"
    check_services "$namespace"
    check_pv_pvc
    check_resource_usage
    check_recent_events "$namespace"
    check_certificate_expiry

    echo ""
    generate_summary
}

# Main script
main() {
    local namespace=""
    local output_file=""
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                namespace="$2"
                shift 2
                ;;
            -o|--output)
                output_file="$2"
                shift 2
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -q|--quiet)
                # Could implement quiet mode
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    check_prerequisites

    if [ -n "$output_file" ]; then
        run_diagnostics "$namespace" | tee "$output_file"
        print_info "Report saved to: $output_file"
    else
        run_diagnostics "$namespace"
    fi
}

main "$@"
