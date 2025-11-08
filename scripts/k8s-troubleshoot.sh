#!/usr/bin/env bash
#
# k8s-troubleshoot.sh - Kubernetes Troubleshooting Helper
# Based on official Kubernetes documentation:
# - https://kubernetes.io/docs/tasks/debug/
# - https://kubernetes.io/docs/tasks/debug/debug-application/
# - https://kubernetes.io/docs/tasks/debug/debug-cluster/
#
# This script automates common Kubernetes troubleshooting workflows

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script version
VERSION="1.0.0"

# Default values
NAMESPACE="default"
OUTPUT_DIR="./k8s-troubleshoot-$(date +%Y%m%d-%H%M%S)"
VERBOSE=0

print_header() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

usage() {
    cat << EOF
Kubernetes Troubleshooting Helper v${VERSION}

Usage: $(basename "$0") [OPTIONS] COMMAND [ARGS]

Commands:
    pod <pod-name>              Deep troubleshoot a specific pod
    deployment <name>           Troubleshoot a deployment
    service <name>              Troubleshoot a service
    node <node-name>            Troubleshoot a specific node
    namespace <ns-name>         Troubleshoot an entire namespace
    cluster                     Run cluster-wide diagnostics
    events                      Show recent cluster events
    logs <pod-name>             Collect logs from a pod (all containers)
    interactive                 Interactive troubleshooting mode

Options:
    -n, --namespace <ns>        Kubernetes namespace (default: default)
    -o, --output <dir>          Output directory for collected data
    -v, --verbose               Verbose output
    -h, --help                  Show this help message

Examples:
    # Troubleshoot a specific pod
    $(basename "$0") pod nginx-deployment-abc123 -n production

    # Full namespace diagnostics
    $(basename "$0") namespace production -o /tmp/diagnostics

    # Cluster-wide health check
    $(basename "$0") cluster

    # Interactive mode
    $(basename "$0") interactive

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

    print_success "Prerequisites check passed"
}

collect_pod_diagnostics() {
    local pod_name="$1"
    local namespace="$2"

    print_header "Pod Diagnostics: $pod_name (namespace: $namespace)"

    # Check if pod exists
    if ! kubectl get pod "$pod_name" -n "$namespace" &> /dev/null; then
        print_error "Pod '$pod_name' not found in namespace '$namespace'"
        return 1
    fi

    # Pod status
    print_info "Pod Status:"
    kubectl get pod "$pod_name" -n "$namespace" -o wide

    echo ""
    print_info "Pod Details:"
    kubectl describe pod "$pod_name" -n "$namespace"

    echo ""
    print_info "Pod YAML:"
    kubectl get pod "$pod_name" -n "$namespace" -o yaml

    echo ""
    print_info "Pod Events (last 50):"
    kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" \
        --sort-by='.lastTimestamp' | tail -n 50

    echo ""
    print_info "Container Logs:"
    # Get all containers in the pod
    local containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}')
    for container in $containers; do
        echo ""
        print_info "Logs from container: $container"
        kubectl logs "$pod_name" -n "$namespace" -c "$container" --tail=100 || print_warning "Failed to get logs for container $container"

        # Also get previous logs if container restarted
        if kubectl logs "$pod_name" -n "$namespace" -c "$container" --previous &> /dev/null; then
            echo ""
            print_warning "Previous logs from container: $container (container restarted)"
            kubectl logs "$pod_name" -n "$namespace" -c "$container" --previous --tail=100
        fi
    done

    # Check init containers
    local init_containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.initContainers[*].name}')
    if [ -n "$init_containers" ]; then
        echo ""
        print_info "Init Containers Found:"
        for container in $init_containers; do
            echo ""
            print_info "Logs from init container: $container"
            kubectl logs "$pod_name" -n "$namespace" -c "$container" --tail=100 || print_warning "Failed to get logs for init container $container"
        done
    fi

    echo ""
    print_info "Resource Usage (if metrics-server is available):"
    kubectl top pod "$pod_name" -n "$namespace" 2>/dev/null || print_warning "Metrics not available (metrics-server may not be installed)"

    echo ""
    print_success "Pod diagnostics completed for $pod_name"
}

troubleshoot_deployment() {
    local deployment_name="$1"
    local namespace="$2"

    print_header "Deployment Diagnostics: $deployment_name (namespace: $namespace)"

    # Check if deployment exists
    if ! kubectl get deployment "$deployment_name" -n "$namespace" &> /dev/null; then
        print_error "Deployment '$deployment_name' not found in namespace '$namespace'"
        return 1
    fi

    # Deployment status
    print_info "Deployment Status:"
    kubectl get deployment "$deployment_name" -n "$namespace" -o wide

    echo ""
    print_info "Deployment Details:"
    kubectl describe deployment "$deployment_name" -n "$namespace"

    echo ""
    print_info "ReplicaSets for this Deployment:"
    kubectl get rs -n "$namespace" -l "$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{range .spec.selector.matchLabels}{@}{","}{end}' | sed 's/,$//' | sed 's/,/,/g')" 2>/dev/null || kubectl get rs -n "$namespace" | grep "$deployment_name"

    echo ""
    print_info "Pods for this Deployment:"
    local selector=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
    if [ -n "$selector" ]; then
        kubectl get pods -n "$namespace" -l "$selector" -o wide
    else
        print_warning "Could not determine pod selector"
    fi

    echo ""
    print_info "Deployment Events:"
    kubectl get events -n "$namespace" --field-selector involvedObject.name="$deployment_name" \
        --sort-by='.lastTimestamp' | tail -n 20

    echo ""
    print_info "Rollout Status:"
    kubectl rollout status deployment/"$deployment_name" -n "$namespace"

    echo ""
    print_info "Rollout History:"
    kubectl rollout history deployment/"$deployment_name" -n "$namespace"

    print_success "Deployment diagnostics completed for $deployment_name"
}

troubleshoot_service() {
    local service_name="$1"
    local namespace="$2"

    print_header "Service Diagnostics: $service_name (namespace: $namespace)"

    # Check if service exists
    if ! kubectl get service "$service_name" -n "$namespace" &> /dev/null; then
        print_error "Service '$service_name' not found in namespace '$namespace'"
        return 1
    fi

    # Service details
    print_info "Service Details:"
    kubectl describe service "$service_name" -n "$namespace"

    echo ""
    print_info "Service YAML:"
    kubectl get service "$service_name" -n "$namespace" -o yaml

    echo ""
    print_info "Endpoints:"
    kubectl get endpoints "$service_name" -n "$namespace"

    echo ""
    print_info "Checking if service has backends:"
    local endpoints=$(kubectl get endpoints "$service_name" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}')
    if [ -z "$endpoints" ]; then
        print_warning "No endpoints found! The service may have no matching pods."
        echo ""
        print_info "Service Selector:"
        kubectl get service "$service_name" -n "$namespace" -o jsonpath='{.spec.selector}' | jq .

        echo ""
        print_info "Checking for pods matching the selector:"
        local selector=$(kubectl get service "$service_name" -n "$namespace" -o jsonpath='{.spec.selector}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        if [ -n "$selector" ]; then
            kubectl get pods -n "$namespace" -l "$selector"
        fi
    else
        print_success "Service has endpoints: $endpoints"
    fi

    echo ""
    print_info "Service Events:"
    kubectl get events -n "$namespace" --field-selector involvedObject.name="$service_name" \
        --sort-by='.lastTimestamp' | tail -n 20

    print_success "Service diagnostics completed for $service_name"
}

troubleshoot_node() {
    local node_name="$1"

    print_header "Node Diagnostics: $node_name"

    # Check if node exists
    if ! kubectl get node "$node_name" &> /dev/null; then
        print_error "Node '$node_name' not found"
        return 1
    fi

    # Node status
    print_info "Node Status:"
    kubectl get node "$node_name" -o wide

    echo ""
    print_info "Node Details:"
    kubectl describe node "$node_name"

    echo ""
    print_info "Node Conditions:"
    kubectl get node "$node_name" -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' | column -t

    echo ""
    print_info "Node Capacity and Allocatable Resources:"
    echo "Resource    Capacity    Allocatable"
    kubectl get node "$node_name" -o jsonpath='{range .status.capacity}{@}{"\t"}{end}{"\n"}{range .status.allocatable}{@}{"\t"}{end}' | awk '{print $1"\t"$2"\t"$5"\n"$3"\t"$4"\t"$6}'

    echo ""
    print_info "Pods Running on Node:"
    kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o wide

    echo ""
    print_info "Node Resource Usage (if metrics-server is available):"
    kubectl top node "$node_name" 2>/dev/null || print_warning "Metrics not available (metrics-server may not be installed)"

    echo ""
    print_info "Node Events (last 50):"
    kubectl get events --all-namespaces --field-selector involvedObject.name="$node_name" \
        --sort-by='.lastTimestamp' | tail -n 50

    print_success "Node diagnostics completed for $node_name"
}

troubleshoot_namespace() {
    local namespace="$1"

    print_header "Namespace Diagnostics: $namespace"

    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        print_error "Namespace '$namespace' not found"
        return 1
    fi

    # Namespace details
    print_info "Namespace Details:"
    kubectl describe namespace "$namespace"

    echo ""
    print_info "Resource Quotas:"
    kubectl get resourcequota -n "$namespace" || print_info "No resource quotas defined"

    echo ""
    print_info "Limit Ranges:"
    kubectl get limitrange -n "$namespace" || print_info "No limit ranges defined"

    echo ""
    print_info "All Resources in Namespace:"
    kubectl get all -n "$namespace" -o wide

    echo ""
    print_info "Pods Status Summary:"
    kubectl get pods -n "$namespace" --no-headers | awk '{print $3}' | sort | uniq -c

    echo ""
    print_info "Failed/Problem Pods:"
    kubectl get pods -n "$namespace" --field-selector=status.phase!=Running,status.phase!=Succeeded

    echo ""
    print_info "Recent Events in Namespace (last 50):"
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -n 50

    echo ""
    print_info "ConfigMaps:"
    kubectl get configmaps -n "$namespace"

    echo ""
    print_info "Secrets:"
    kubectl get secrets -n "$namespace"

    echo ""
    print_info "Services:"
    kubectl get services -n "$namespace" -o wide

    echo ""
    print_info "PersistentVolumeClaims:"
    kubectl get pvc -n "$namespace" || print_info "No PVCs found"

    print_success "Namespace diagnostics completed for $namespace"
}

cluster_diagnostics() {
    print_header "Cluster-Wide Diagnostics"

    print_info "Cluster Info:"
    kubectl cluster-info

    echo ""
    print_info "Cluster Version:"
    kubectl version --short 2>/dev/null || kubectl version

    echo ""
    print_info "Node Status:"
    kubectl get nodes -o wide

    echo ""
    print_info "Node Conditions Summary:"
    kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status'

    echo ""
    print_info "Component Status:"
    kubectl get --raw /healthz?verbose 2>/dev/null || print_warning "Health endpoint not accessible"

    echo ""
    print_info "API Resources:"
    kubectl api-resources | head -n 20
    echo "... (showing first 20, run 'kubectl api-resources' for full list)"

    echo ""
    print_info "Namespaces:"
    kubectl get namespaces

    echo ""
    print_info "Cluster-Wide Events (last 100):"
    kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -n 100

    echo ""
    print_info "Recent Warning Events:"
    kubectl get events --all-namespaces --field-selector type=Warning --sort-by='.lastTimestamp' | tail -n 30

    echo ""
    print_info "PersistentVolumes:"
    kubectl get pv

    echo ""
    print_info "StorageClasses:"
    kubectl get storageclass

    echo ""
    print_info "Cluster Resource Usage (if metrics-server is available):"
    kubectl top nodes 2>/dev/null || print_warning "Metrics not available (metrics-server may not be installed)"

    echo ""
    print_info "Control Plane Pods:"
    kubectl get pods -n kube-system -o wide

    echo ""
    print_info "Failed Pods Across All Namespaces:"
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded

    print_success "Cluster diagnostics completed"
}

show_events() {
    local namespace="${1:-}"

    if [ -z "$namespace" ]; then
        print_header "Cluster-Wide Events"
        kubectl get events --all-namespaces --sort-by='.lastTimestamp'
    else
        print_header "Events in Namespace: $namespace"
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp'
    fi
}

collect_all_logs() {
    local pod_name="$1"
    local namespace="$2"
    local output_dir="${3:-$OUTPUT_DIR}"

    mkdir -p "$output_dir"

    print_header "Collecting All Logs from Pod: $pod_name"

    # Get all containers
    local containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}')

    for container in $containers; do
        print_info "Collecting logs from container: $container"
        kubectl logs "$pod_name" -n "$namespace" -c "$container" > "$output_dir/${pod_name}_${container}.log" 2>&1

        # Previous logs if available
        if kubectl logs "$pod_name" -n "$namespace" -c "$container" --previous &> /dev/null; then
            kubectl logs "$pod_name" -n "$namespace" -c "$container" --previous > "$output_dir/${pod_name}_${container}_previous.log" 2>&1
        fi
    done

    # Init containers
    local init_containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.initContainers[*].name}')
    for container in $init_containers; do
        print_info "Collecting logs from init container: $container"
        kubectl logs "$pod_name" -n "$namespace" -c "$container" > "$output_dir/${pod_name}_init_${container}.log" 2>&1
    done

    print_success "Logs saved to $output_dir"
}

interactive_mode() {
    print_header "Interactive Troubleshooting Mode"

    while true; do
        echo ""
        echo "What would you like to troubleshoot?"
        echo "1) Pod"
        echo "2) Deployment"
        echo "3) Service"
        echo "4) Node"
        echo "5) Namespace"
        echo "6) Cluster (overall health)"
        echo "7) Show recent events"
        echo "8) Exit"
        echo ""
        read -p "Select an option (1-8): " choice

        case $choice in
            1)
                read -p "Enter namespace (default: default): " ns
                ns=${ns:-default}
                read -p "Enter pod name: " pod
                if [ -n "$pod" ]; then
                    collect_pod_diagnostics "$pod" "$ns"
                fi
                ;;
            2)
                read -p "Enter namespace (default: default): " ns
                ns=${ns:-default}
                read -p "Enter deployment name: " deploy
                if [ -n "$deploy" ]; then
                    troubleshoot_deployment "$deploy" "$ns"
                fi
                ;;
            3)
                read -p "Enter namespace (default: default): " ns
                ns=${ns:-default}
                read -p "Enter service name: " svc
                if [ -n "$svc" ]; then
                    troubleshoot_service "$svc" "$ns"
                fi
                ;;
            4)
                read -p "Enter node name: " node
                if [ -n "$node" ]; then
                    troubleshoot_node "$node"
                fi
                ;;
            5)
                read -p "Enter namespace name: " ns
                if [ -n "$ns" ]; then
                    troubleshoot_namespace "$ns"
                fi
                ;;
            6)
                cluster_diagnostics
                ;;
            7)
                read -p "Enter namespace (leave empty for all namespaces): " ns
                show_events "$ns"
                ;;
            8)
                print_info "Exiting interactive mode"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                ;;
        esac
    done
}

# Main script logic
main() {
    if [ $# -eq 0 ]; then
        usage
    fi

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            pod)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Pod name is required"
                    exit 1
                fi
                collect_pod_diagnostics "$2" "$NAMESPACE"
                exit 0
                ;;
            deployment)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Deployment name is required"
                    exit 1
                fi
                troubleshoot_deployment "$2" "$NAMESPACE"
                exit 0
                ;;
            service)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Service name is required"
                    exit 1
                fi
                troubleshoot_service "$2" "$NAMESPACE"
                exit 0
                ;;
            node)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Node name is required"
                    exit 1
                fi
                troubleshoot_node "$2"
                exit 0
                ;;
            namespace)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Namespace name is required"
                    exit 1
                fi
                troubleshoot_namespace "$2"
                exit 0
                ;;
            cluster)
                check_prerequisites
                cluster_diagnostics
                exit 0
                ;;
            events)
                check_prerequisites
                show_events "$NAMESPACE"
                exit 0
                ;;
            logs)
                check_prerequisites
                if [ -z "${2:-}" ]; then
                    print_error "Pod name is required"
                    exit 1
                fi
                collect_all_logs "$2" "$NAMESPACE"
                exit 0
                ;;
            interactive)
                check_prerequisites
                interactive_mode
                exit 0
                ;;
            *)
                print_error "Unknown command or option: $1"
                usage
                ;;
        esac
    done
}

main "$@"
