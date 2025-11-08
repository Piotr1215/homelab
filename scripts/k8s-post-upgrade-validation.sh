#!/bin/bash
#####################################################################
# Kubernetes Post-Upgrade Validation Script
#
# This script performs comprehensive validation after a Kubernetes
# cluster upgrade to ensure everything is working correctly.
#
# Features:
# - Version verification across all nodes
# - Component health checks
# - Pod status validation
# - Service connectivity tests
# - PersistentVolume status checks
# - API server functionality tests
# - DNS resolution tests
# - Metrics collection
#
# Usage: ./k8s-post-upgrade-validation.sh [expected-version]
# Example: ./k8s-post-upgrade-validation.sh v1.33.0
#####################################################################

set -euo pipefail

# Configuration
EXPECTED_VERSION="${1:-}"
LOG_FILE="${LOG_FILE:-/tmp/k8s-post-validation-$(date +%Y%m%d-%H%M%S).log}"
REPORT_FILE="${REPORT_FILE:-/tmp/k8s-validation-report-$(date +%Y%m%d-%H%M%S).txt}"
TEST_NAMESPACE="${TEST_NAMESPACE:-default}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1" | tee -a "$LOG_FILE"
    ((TESTS_PASSED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
    ((TESTS_WARNING++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1" | tee -a "$LOG_FILE"
    ((TESTS_FAILED++))
}

log_section() {
    echo -e "\n${MAGENTA}===================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}===================================================${NC}\n" | tee -a "$LOG_FILE"
}

test_start() {
    ((TESTS_TOTAL++))
}

# Check cluster connectivity
check_cluster_connectivity() {
    log_section "Test 1: Cluster Connectivity"
    test_start

    if kubectl cluster-info &> /dev/null; then
        log_success "Cluster is reachable"
        kubectl cluster-info | tee -a "$LOG_FILE"
    else
        log_error "Cannot connect to cluster"
        return 1
    fi
}

# Verify node versions
verify_node_versions() {
    log_section "Test 2: Node Version Verification"

    log_info "Checking node versions..."
    kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,STATUS:.status.conditions[?@.type==\"Ready\"].status,OS:.status.nodeInfo.osImage | tee -a "$LOG_FILE"

    # Check each node
    local all_nodes_correct=true
    while IFS= read -r node; do
        test_start
        local version=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')

        if [ -n "$EXPECTED_VERSION" ]; then
            if [ "$version" = "$EXPECTED_VERSION" ]; then
                log_success "Node $node version: $version"
            else
                log_error "Node $node version mismatch: expected $EXPECTED_VERSION, got $version"
                all_nodes_correct=false
            fi
        else
            log_info "Node $node version: $version"
            ((TESTS_PASSED++))
        fi
    done < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

    # Check version consistency
    test_start
    local version_count=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' | tr ' ' '\n' | sort -u | wc -l)
    if [ "$version_count" -eq 1 ]; then
        log_success "All nodes are running the same version"
    else
        log_warning "Nodes are running different versions (mixed version cluster detected)"
    fi
}

# Check node status
check_node_status() {
    log_section "Test 3: Node Health Status"

    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready " || echo "0")

    test_start
    log_info "Total nodes: $total_nodes"
    log_info "Ready nodes: $ready_nodes"

    if [ "$total_nodes" -eq "$ready_nodes" ]; then
        log_success "All $total_nodes nodes are Ready"
    else
        log_error "Only $ready_nodes out of $total_nodes nodes are Ready"
    fi

    # Check for pressure conditions
    log_info "Checking for node pressure conditions..."
    local nodes_with_issues=0

    while IFS= read -r node; do
        test_start
        local conditions=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')

        if echo "$conditions" | grep -q "MemoryPressure"; then
            log_warning "Node $node has MemoryPressure"
            ((nodes_with_issues++))
        elif echo "$conditions" | grep -q "DiskPressure"; then
            log_warning "Node $node has DiskPressure"
            ((nodes_with_issues++))
        elif echo "$conditions" | grep -q "PIDPressure"; then
            log_warning "Node $node has PIDPressure"
            ((nodes_with_issues++))
        else
            log_success "Node $node has no pressure conditions"
        fi
    done < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

    test_start
    if [ "$nodes_with_issues" -eq 0 ]; then
        log_success "No nodes have resource pressure"
    else
        log_warning "$nodes_with_issues nodes have resource pressure"
    fi
}

# Check system pods
check_system_pods() {
    log_section "Test 4: System Pod Status"

    local namespaces="kube-system kube-public kube-node-lease"

    for ns in $namespaces; do
        test_start
        log_info "Checking namespace: $ns"

        local total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        local running=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        local pending=$(kubectl get pods -n "$ns" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
        local failed=$(kubectl get pods -n "$ns" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)

        log_info "  Total: $total, Running: $running, Pending: $pending, Failed: $failed"

        if [ "$failed" -gt 0 ]; then
            log_error "Namespace $ns has $failed failed pods"
            kubectl get pods -n "$ns" --field-selector=status.phase=Failed | tee -a "$LOG_FILE"
        elif [ "$pending" -gt 0 ]; then
            log_warning "Namespace $ns has $pending pending pods"
        else
            log_success "All pods in $ns are running"
        fi
    done
}

# Check critical components
check_critical_components() {
    log_section "Test 5: Critical Component Status"

    local components=(
        "kube-system:kube-apiserver:component=kube-apiserver"
        "kube-system:kube-controller-manager:component=kube-controller-manager"
        "kube-system:kube-scheduler:component=kube-scheduler"
        "kube-system:etcd:component=etcd"
        "kube-system:kube-proxy:k8s-app=kube-proxy"
        "kube-system:coredns:k8s-app=kube-dns"
    )

    for comp_info in "${components[@]}"; do
        test_start
        local ns=$(echo "$comp_info" | cut -d: -f1)
        local name=$(echo "$comp_info" | cut -d: -f2)
        local label=$(echo "$comp_info" | cut -d: -f3)

        local pod_count=$(kubectl get pods -n "$ns" -l "$label" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

        if [ "$pod_count" -gt 0 ]; then
            log_success "$name is running ($pod_count instances)"
        else
            log_error "$name is not running (0 instances)"
        fi
    done
}

# Test API server
test_api_server() {
    log_section "Test 6: API Server Functionality"

    # Test basic API operations
    test_start
    if kubectl get namespaces &> /dev/null; then
        log_success "API server responds to GET requests"
    else
        log_error "API server not responding to GET requests"
    fi

    # Test API server health endpoints
    test_start
    local api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    log_info "API server: $api_server"

    if kubectl get --raw='/healthz' &> /dev/null; then
        log_success "API server /healthz endpoint is healthy"
    else
        log_warning "API server /healthz endpoint check failed"
    fi

    test_start
    if kubectl get --raw='/readyz' &> /dev/null; then
        log_success "API server /readyz endpoint is ready"
    else
        log_warning "API server /readyz endpoint check failed"
    fi

    # Test API resources
    test_start
    if kubectl api-resources &> /dev/null; then
        log_success "API resources are accessible"
    else
        log_error "Cannot list API resources"
    fi
}

# Test DNS resolution
test_dns_resolution() {
    log_section "Test 7: DNS Resolution"

    log_info "Testing DNS resolution with temporary pod..."

    # Create a test pod for DNS testing
    test_start
    local test_pod="dns-test-$$"

    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${test_pod}
  namespace: ${TEST_NAMESPACE}
spec:
  containers:
  - name: test
    image: busybox:1.36
    command: ['sh', '-c', 'sleep 3600']
  restartPolicy: Never
EOF

    # Wait for pod to be ready
    log_info "Waiting for test pod to be ready..."
    if kubectl wait --for=condition=ready pod/${test_pod} -n ${TEST_NAMESPACE} --timeout=60s &> /dev/null; then
        log_success "Test pod created successfully"

        # Test DNS resolution
        test_start
        if kubectl exec ${test_pod} -n ${TEST_NAMESPACE} -- nslookup kubernetes.default &> /dev/null; then
            log_success "DNS resolution is working (kubernetes.default)"
        else
            log_error "DNS resolution failed"
        fi

        # Test external DNS
        test_start
        if kubectl exec ${test_pod} -n ${TEST_NAMESPACE} -- nslookup google.com &> /dev/null; then
            log_success "External DNS resolution is working"
        else
            log_warning "External DNS resolution failed (may be expected in restricted environments)"
        fi
    else
        log_warning "Test pod did not become ready in time"
    fi

    # Cleanup
    kubectl delete pod ${test_pod} -n ${TEST_NAMESPACE} --grace-period=0 --force &> /dev/null || true
}

# Check persistent volumes
check_persistent_volumes() {
    log_section "Test 8: Persistent Volume Status"

    local total_pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)

    if [ "$total_pvs" -eq 0 ]; then
        log_info "No persistent volumes in cluster"
        return 0
    fi

    log_info "Total PVs: $total_pvs"
    kubectl get pv -o wide | tee -a "$LOG_FILE"

    test_start
    local available=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Available" || echo "0")
    local bound=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Bound" || echo "0")
    local released=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Released" || echo "0")
    local failed=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Failed" || echo "0")

    log_info "PV Status: Available=$available, Bound=$bound, Released=$released, Failed=$failed"

    if [ "$failed" -eq 0 ]; then
        log_success "No failed persistent volumes"
    else
        log_error "$failed persistent volumes in Failed state"
    fi

    # Check PVCs
    test_start
    log_info "Checking PersistentVolumeClaims..."
    local pending_pvcs=$(kubectl get pvc --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)

    if [ "$pending_pvcs" -eq 0 ]; then
        log_success "No pending PVCs"
    else
        log_warning "$pending_pvcs PVCs in Pending state"
        kubectl get pvc --all-namespaces --field-selector=status.phase=Pending | tee -a "$LOG_FILE"
    fi
}

# Check services
check_services() {
    log_section "Test 9: Service Status"

    test_start
    log_info "Checking Kubernetes service..."
    if kubectl get svc kubernetes -n default &> /dev/null; then
        log_success "Kubernetes service is available"
    else
        log_error "Kubernetes service not found"
    fi

    # Check for services with issues
    test_start
    log_info "Checking for LoadBalancer services..."
    local lb_count=$(kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer --no-headers 2>/dev/null | wc -l)
    log_info "Found $lb_count LoadBalancer services"

    if [ "$lb_count" -gt 0 ]; then
        local pending_lb=$(kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer -o json | jq -r '.items[] | select(.status.loadBalancer.ingress == null) | .metadata.namespace + "/" + .metadata.name' 2>/dev/null | wc -l)

        if [ "$pending_lb" -eq 0 ]; then
            log_success "All LoadBalancer services have external IPs"
        else
            log_warning "$pending_lb LoadBalancer services pending external IP"
        fi
    fi
}

# Check deployments
check_deployments() {
    log_section "Test 10: Deployment Status"

    log_info "Checking deployment status across all namespaces..."

    local deployments=$(kubectl get deployments --all-namespaces -o json 2>/dev/null)

    if [ -z "$deployments" ] || [ "$deployments" = '{"items":[]}' ]; then
        log_info "No deployments found in cluster"
        return 0
    fi

    local total_deployments=$(echo "$deployments" | jq -r '.items | length')
    log_info "Total deployments: $total_deployments"

    local unhealthy=0

    while IFS= read -r deployment; do
        test_start
        local ns=$(echo "$deployment" | jq -r '.metadata.namespace')
        local name=$(echo "$deployment" | jq -r '.metadata.name')
        local desired=$(echo "$deployment" | jq -r '.spec.replicas // 0')
        local ready=$(echo "$deployment" | jq -r '.status.readyReplicas // 0')
        local available=$(echo "$deployment" | jq -r '.status.availableReplicas // 0')

        if [ "$desired" -eq "$ready" ] && [ "$desired" -eq "$available" ]; then
            log_success "Deployment $ns/$name: $ready/$desired replicas ready"
        else
            log_warning "Deployment $ns/$name: $ready/$desired replicas ready (available: $available)"
            ((unhealthy++))
        fi
    done < <(echo "$deployments" | jq -c '.items[]')

    test_start
    if [ "$unhealthy" -eq 0 ]; then
        log_success "All deployments are healthy"
    else
        log_warning "$unhealthy deployments have replica mismatches"
    fi
}

# Check daemonsets
check_daemonsets() {
    log_section "Test 11: DaemonSet Status"

    log_info "Checking DaemonSet status..."

    local daemonsets=$(kubectl get daemonsets --all-namespaces -o json 2>/dev/null)

    if [ -z "$daemonsets" ] || [ "$daemonsets" = '{"items":[]}' ]; then
        log_info "No daemonsets found in cluster"
        return 0
    fi

    local total_ds=$(echo "$daemonsets" | jq -r '.items | length')
    log_info "Total daemonsets: $total_ds"

    local unhealthy=0

    while IFS= read -r ds; do
        test_start
        local ns=$(echo "$ds" | jq -r '.metadata.namespace')
        local name=$(echo "$ds" | jq -r '.metadata.name')
        local desired=$(echo "$ds" | jq -r '.status.desiredNumberScheduled // 0')
        local ready=$(echo "$ds" | jq -r '.status.numberReady // 0')

        if [ "$desired" -eq "$ready" ]; then
            log_success "DaemonSet $ns/$name: $ready/$desired ready"
        else
            log_warning "DaemonSet $ns/$name: $ready/$desired ready"
            ((unhealthy++))
        fi
    done < <(echo "$daemonsets" | jq -c '.items[]')

    test_start
    if [ "$unhealthy" -eq 0 ]; then
        log_success "All daemonsets are healthy"
    else
        log_warning "$unhealthy daemonsets have pod mismatches"
    fi
}

# Check resource metrics
check_resource_metrics() {
    log_section "Test 12: Resource Metrics"

    test_start
    if kubectl top nodes &> /dev/null; then
        log_success "Metrics server is available"
        kubectl top nodes | tee -a "$LOG_FILE"

        test_start
        log_info "Pod resource usage:"
        if kubectl top pods --all-namespaces 2>&1 | head -20 | tee -a "$LOG_FILE"; then
            log_success "Pod metrics are available"
        fi
    else
        log_warning "Metrics server not available or not responding"
    fi
}

# Check certificates
check_certificates() {
    log_section "Test 13: Certificate Expiration"

    test_start
    log_info "Checking certificate expiration..."

    if command -v kubeadm &> /dev/null && sudo -n true 2>/dev/null; then
        if sudo kubeadm certs check-expiration 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Certificate expiration check completed"

            # Check for certificates expiring soon (< 30 days)
            if sudo kubeadm certs check-expiration 2>&1 | grep -q "< 30d"; then
                log_warning "Some certificates expire in less than 30 days"
            else
                log_success "All certificates are valid for > 30 days"
            fi
        else
            log_warning "Could not check certificate expiration"
        fi
    else
        log_info "Certificate check skipped (requires kubeadm and sudo)"
    fi
}

# Test pod scheduling
test_pod_scheduling() {
    log_section "Test 14: Pod Scheduling"

    log_info "Testing pod scheduling with temporary pod..."
    test_start

    local test_pod="schedule-test-$$"

    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${test_pod}
  namespace: ${TEST_NAMESPACE}
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
  restartPolicy: Never
EOF

    # Wait for pod to be scheduled
    log_info "Waiting for pod to be scheduled..."
    sleep 5

    local phase=$(kubectl get pod ${test_pod} -n ${TEST_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    local node=$(kubectl get pod ${test_pod} -n ${TEST_NAMESPACE} -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")

    if [ -n "$node" ] && [ "$phase" = "Running" ]; then
        log_success "Pod scheduling is working (scheduled to $node)"
    elif [ "$phase" = "Pending" ]; then
        log_warning "Pod is pending (may be pulling image)"
    else
        log_error "Pod scheduling failed (phase: $phase)"
    fi

    # Cleanup
    kubectl delete pod ${test_pod} -n ${TEST_NAMESPACE} --grace-period=0 --force &> /dev/null || true
}

# Generate validation report
generate_report() {
    log_section "Generating Validation Report"

    cat > "$REPORT_FILE" <<EOF
Kubernetes Post-Upgrade Validation Report
==========================================
Generated: $(date)
Expected Version: ${EXPECTED_VERSION:-Not specified}
Cluster Version: $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')

Test Summary
============
Total Tests: $TESTS_TOTAL
Passed: $TESTS_PASSED
Failed: $TESTS_FAILED
Warnings: $TESTS_WARNING

Test Results
============
EOF

    # Add detailed results from log
    cat "$LOG_FILE" >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" <<EOF

Cluster Overview
================
Nodes:
$(kubectl get nodes -o wide)

System Pods:
$(kubectl get pods -n kube-system)

Deployments:
$(kubectl get deployments --all-namespaces)

Services:
$(kubectl get svc --all-namespaces)

EOF

    log_success "Validation report saved to: $REPORT_FILE"
}

# Main execution
main() {
    log_section "Kubernetes Post-Upgrade Validation"
    log_info "Starting validation at $(date)"
    log_info "Log file: $LOG_FILE"
    log_info "Report file: $REPORT_FILE"

    if [ -n "$EXPECTED_VERSION" ]; then
        log_info "Expected version: $EXPECTED_VERSION"
    fi

    # Run all validation tests
    check_cluster_connectivity
    verify_node_versions
    check_node_status
    check_system_pods
    check_critical_components
    test_api_server
    test_dns_resolution
    check_persistent_volumes
    check_services
    check_deployments
    check_daemonsets
    check_resource_metrics
    check_certificates
    test_pod_scheduling

    # Generate report
    generate_report

    # Final summary
    log_section "Validation Complete"

    local success_rate=0
    if [ "$TESTS_TOTAL" -gt 0 ]; then
        success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    fi

    cat <<EOF | tee -a "$LOG_FILE"
Results Summary:
- Total Tests: $TESTS_TOTAL
- Passed: $TESTS_PASSED (${success_rate}%)
- Failed: $TESTS_FAILED
- Warnings: $TESTS_WARNING

Report: $REPORT_FILE
Log: $LOG_FILE
EOF

    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_success "All critical tests passed! Cluster upgrade validated successfully."
        exit 0
    else
        log_error "$TESTS_FAILED tests failed. Please review the issues."
        exit 1
    fi
}

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Warning: jq is not installed. Some tests may not work properly."
    echo "Install jq: sudo apt-get install jq"
fi

# Run main function
main
