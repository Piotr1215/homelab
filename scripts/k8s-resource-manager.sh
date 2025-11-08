#!/usr/bin/env bash
#
# k8s-resource-manager.sh - Kubernetes Resource Management Helper
# Based on official Kubernetes documentation:
# - https://kubernetes.io/docs/tasks/administer-cluster/
# - Resource quotas and limits management
#
# This script helps manage resource quotas, limits, and resource allocation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION="1.0.0"

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
Kubernetes Resource Management Helper v${VERSION}

Usage: $(basename "$0") COMMAND [OPTIONS]

Commands:
    quota-status [namespace]        Show resource quota status
    quota-create <namespace>        Create resource quota for namespace
    limitrange-status [namespace]   Show limit ranges
    limitrange-create <namespace>   Create limit range for namespace
    resource-usage [namespace]      Show resource usage summary
    top-consumers [namespace]       Show top resource consumers
    check-requests                  Check pods without resource requests
    audit [namespace]               Full resource audit
    interactive                     Interactive resource management

Options:
    -n, --namespace <ns>    Kubernetes namespace (default: all)
    -h, --help              Show this help message

Examples:
    # Show quota status across all namespaces
    $(basename "$0") quota-status

    # Create resource quota for a namespace
    $(basename "$0") quota-create production

    # Audit resource usage
    $(basename "$0") audit production

    # Find top resource consumers
    $(basename "$0") top-consumers

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

show_quota_status() {
    local namespace="${1:-}"

    if [ -z "$namespace" ]; then
        print_header "Resource Quota Status (All Namespaces)"

        # Get all namespaces with quotas
        local namespaces=$(kubectl get resourcequota --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)

        if [ -z "$namespaces" ]; then
            print_warning "No resource quotas found in any namespace"
            return
        fi

        for ns in $namespaces; do
            echo ""
            print_info "Namespace: $ns"
            kubectl get resourcequota -n "$ns"
            echo ""
            kubectl describe resourcequota -n "$ns"
        done
    else
        print_header "Resource Quota Status: $namespace"

        if ! kubectl get resourcequota -n "$namespace" &> /dev/null; then
            print_warning "No resource quotas found in namespace '$namespace'"
            return
        fi

        kubectl get resourcequota -n "$namespace"
        echo ""
        kubectl describe resourcequota -n "$namespace"
    fi
}

create_resource_quota() {
    local namespace="$1"

    print_header "Create Resource Quota for Namespace: $namespace"

    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        print_error "Namespace '$namespace' does not exist"
        read -p "Would you like to create it? (y/n): " create_ns
        if [ "$create_ns" = "y" ]; then
            kubectl create namespace "$namespace"
            print_success "Namespace '$namespace' created"
        else
            return 1
        fi
    fi

    # Interactive quota creation
    echo "Enter resource quota values (press Enter to skip):"

    read -p "CPU requests (e.g., 10): " cpu_requests
    read -p "CPU limits (e.g., 20): " cpu_limits
    read -p "Memory requests (e.g., 10Gi): " memory_requests
    read -p "Memory limits (e.g., 20Gi): " memory_limits
    read -p "Number of pods (e.g., 50): " pod_count
    read -p "Number of services (e.g., 10): " service_count
    read -p "Number of PVCs (e.g., 10): " pvc_count

    # Build quota YAML
    local quota_yaml="apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${namespace}-quota
  namespace: ${namespace}
spec:
  hard:"

    [ -n "$cpu_requests" ] && quota_yaml="${quota_yaml}
    requests.cpu: \"${cpu_requests}\""
    [ -n "$cpu_limits" ] && quota_yaml="${quota_yaml}
    limits.cpu: \"${cpu_limits}\""
    [ -n "$memory_requests" ] && quota_yaml="${quota_yaml}
    requests.memory: ${memory_requests}"
    [ -n "$memory_limits" ] && quota_yaml="${quota_yaml}
    limits.memory: ${memory_limits}"
    [ -n "$pod_count" ] && quota_yaml="${quota_yaml}
    pods: \"${pod_count}\""
    [ -n "$service_count" ] && quota_yaml="${quota_yaml}
    services: \"${service_count}\""
    [ -n "$pvc_count" ] && quota_yaml="${quota_yaml}
    persistentvolumeclaims: \"${pvc_count}\""

    echo ""
    print_info "Generated Resource Quota YAML:"
    echo "$quota_yaml"
    echo ""

    read -p "Apply this resource quota? (y/n): " apply_quota
    if [ "$apply_quota" = "y" ]; then
        echo "$quota_yaml" | kubectl apply -f -
        print_success "Resource quota created for namespace '$namespace'"
    else
        print_info "Resource quota not applied"
    fi
}

show_limitrange_status() {
    local namespace="${1:-}"

    if [ -z "$namespace" ]; then
        print_header "Limit Ranges (All Namespaces)"

        local namespaces=$(kubectl get limitrange --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)

        if [ -z "$namespaces" ]; then
            print_warning "No limit ranges found in any namespace"
            return
        fi

        for ns in $namespaces; do
            echo ""
            print_info "Namespace: $ns"
            kubectl get limitrange -n "$ns"
            echo ""
            kubectl describe limitrange -n "$ns"
        done
    else
        print_header "Limit Ranges: $namespace"

        if ! kubectl get limitrange -n "$namespace" &> /dev/null; then
            print_warning "No limit ranges found in namespace '$namespace'"
            return
        fi

        kubectl get limitrange -n "$namespace"
        echo ""
        kubectl describe limitrange -n "$namespace"
    fi
}

create_limitrange() {
    local namespace="$1"

    print_header "Create Limit Range for Namespace: $namespace"

    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        print_error "Namespace '$namespace' does not exist"
        return 1
    fi

    echo "Enter limit range values for containers:"
    echo "(These define default and min/max limits for containers)"
    echo ""

    read -p "Default CPU request (e.g., 100m): " default_cpu_request
    read -p "Default CPU limit (e.g., 200m): " default_cpu_limit
    read -p "Default Memory request (e.g., 128Mi): " default_memory_request
    read -p "Default Memory limit (e.g., 256Mi): " default_memory_limit
    read -p "Min CPU (e.g., 50m, or press Enter to skip): " min_cpu
    read -p "Max CPU (e.g., 2, or press Enter to skip): " max_cpu
    read -p "Min Memory (e.g., 64Mi, or press Enter to skip): " min_memory
    read -p "Max Memory (e.g., 1Gi, or press Enter to skip): " max_memory

    # Build limit range YAML
    local lr_yaml="apiVersion: v1
kind: LimitRange
metadata:
  name: ${namespace}-limitrange
  namespace: ${namespace}
spec:
  limits:
  - type: Container
    default:"

    [ -n "$default_cpu_limit" ] && lr_yaml="${lr_yaml}
      cpu: ${default_cpu_limit}"
    [ -n "$default_memory_limit" ] && lr_yaml="${lr_yaml}
      memory: ${default_memory_limit}"

    lr_yaml="${lr_yaml}
    defaultRequest:"

    [ -n "$default_cpu_request" ] && lr_yaml="${lr_yaml}
      cpu: ${default_cpu_request}"
    [ -n "$default_memory_request" ] && lr_yaml="${lr_yaml}
      memory: ${default_memory_request}"

    if [ -n "$max_cpu" ] || [ -n "$max_memory" ]; then
        lr_yaml="${lr_yaml}
    max:"
        [ -n "$max_cpu" ] && lr_yaml="${lr_yaml}
      cpu: ${max_cpu}"
        [ -n "$max_memory" ] && lr_yaml="${lr_yaml}
      memory: ${max_memory}"
    fi

    if [ -n "$min_cpu" ] || [ -n "$min_memory" ]; then
        lr_yaml="${lr_yaml}
    min:"
        [ -n "$min_cpu" ] && lr_yaml="${lr_yaml}
      cpu: ${min_cpu}"
        [ -n "$min_memory" ] && lr_yaml="${lr_yaml}
      memory: ${min_memory}"
    fi

    echo ""
    print_info "Generated Limit Range YAML:"
    echo "$lr_yaml"
    echo ""

    read -p "Apply this limit range? (y/n): " apply_lr
    if [ "$apply_lr" = "y" ]; then
        echo "$lr_yaml" | kubectl apply -f -
        print_success "Limit range created for namespace '$namespace'"
    else
        print_info "Limit range not applied"
    fi
}

show_resource_usage() {
    local namespace="${1:-}"

    print_header "Resource Usage Summary"

    # Check if metrics-server is available
    if ! kubectl top nodes &> /dev/null; then
        print_warning "metrics-server is not available. Cannot show resource usage."
        print_info "Install metrics-server to enable this feature."
        return 1
    fi

    print_info "Node Resource Usage:"
    kubectl top nodes
    echo ""

    if [ -z "$namespace" ]; then
        print_info "Pod Resource Usage (All Namespaces - Top 20):"
        kubectl top pods --all-namespaces --sort-by=cpu | head -n 21
        echo ""
        kubectl top pods --all-namespaces --sort-by=memory | head -n 21
    else
        print_info "Pod Resource Usage: $namespace"
        kubectl top pods -n "$namespace" --sort-by=cpu
        echo ""
        kubectl top pods -n "$namespace" --sort-by=memory
    fi
}

show_top_consumers() {
    local namespace="${1:-}"

    print_header "Top Resource Consumers"

    if ! kubectl top nodes &> /dev/null; then
        print_warning "metrics-server is not available"
        return 1
    fi

    print_info "Top 10 CPU Consumers:"
    if [ -z "$namespace" ]; then
        kubectl top pods --all-namespaces --sort-by=cpu | head -n 11
    else
        kubectl top pods -n "$namespace" --sort-by=cpu | head -n 11
    fi

    echo ""
    print_info "Top 10 Memory Consumers:"
    if [ -z "$namespace" ]; then
        kubectl top pods --all-namespaces --sort-by=memory | head -n 11
    else
        kubectl top pods -n "$namespace" --sort-by=memory | head -n 11
    fi

    echo ""
    print_info "Pods by Resource Usage Percentage (requires requests to be set):"

    if [ -z "$namespace" ]; then
        kubectl get pods --all-namespaces -o json | jq -r '
            .items[] |
            select(.spec.containers[0].resources.requests != null) |
            {
                namespace: .metadata.namespace,
                name: .metadata.name,
                cpu_request: .spec.containers[0].resources.requests.cpu,
                memory_request: .spec.containers[0].resources.requests.memory
            } |
            "\(.namespace)/\(.name)\t\(.cpu_request)\t\(.memory_request)"
        ' | column -t | head -n 20
    else
        kubectl get pods -n "$namespace" -o json | jq -r '
            .items[] |
            select(.spec.containers[0].resources.requests != null) |
            {
                name: .metadata.name,
                cpu_request: .spec.containers[0].resources.requests.cpu,
                memory_request: .spec.containers[0].resources.requests.memory
            } |
            "\(.name)\t\(.cpu_request)\t\(.memory_request)"
        ' | column -t
    fi
}

check_pods_without_requests() {
    print_header "Pods Without Resource Requests"

    print_info "Checking for pods without CPU or memory requests..."
    echo ""

    local pods_without_requests=$(kubectl get pods --all-namespaces -o json | jq -r '
        .items[] |
        select(
            (.spec.containers[0].resources.requests.cpu == null) or
            (.spec.containers[0].resources.requests.memory == null)
        ) |
        "\(.metadata.namespace)\t\(.metadata.name)"
    ')

    if [ -z "$pods_without_requests" ]; then
        print_success "All pods have resource requests defined"
    else
        print_warning "The following pods are missing resource requests:"
        echo "NAMESPACE    POD_NAME"
        echo "$pods_without_requests" | column -t
        echo ""
        print_info "It's recommended to set resource requests for all pods"
    fi
}

resource_audit() {
    local namespace="${1:-}"

    print_header "Resource Audit"

    echo ""
    print_info "=== Resource Quotas ==="
    show_quota_status "$namespace"

    echo ""
    print_info "=== Limit Ranges ==="
    show_limitrange_status "$namespace"

    echo ""
    print_info "=== Current Resource Usage ==="
    show_resource_usage "$namespace"

    echo ""
    print_info "=== Pods Without Resource Requests ==="
    if [ -z "$namespace" ]; then
        check_pods_without_requests
    else
        kubectl get pods -n "$namespace" -o json | jq -r '
            .items[] |
            select(
                (.spec.containers[0].resources.requests.cpu == null) or
                (.spec.containers[0].resources.requests.memory == null)
            ) |
            .metadata.name
        ' | while read pod; do
            [ -n "$pod" ] && print_warning "Pod '$pod' is missing resource requests"
        done
    fi

    echo ""
    print_success "Resource audit completed"
}

interactive_mode() {
    print_header "Interactive Resource Management"

    while true; do
        echo ""
        echo "What would you like to do?"
        echo "1) View resource quota status"
        echo "2) Create resource quota"
        echo "3) View limit ranges"
        echo "4) Create limit range"
        echo "5) View resource usage"
        echo "6) Show top resource consumers"
        echo "7) Check pods without resource requests"
        echo "8) Full resource audit"
        echo "9) Exit"
        echo ""
        read -p "Select an option (1-9): " choice

        case $choice in
            1)
                read -p "Enter namespace (leave empty for all): " ns
                show_quota_status "$ns"
                ;;
            2)
                read -p "Enter namespace: " ns
                if [ -n "$ns" ]; then
                    create_resource_quota "$ns"
                fi
                ;;
            3)
                read -p "Enter namespace (leave empty for all): " ns
                show_limitrange_status "$ns"
                ;;
            4)
                read -p "Enter namespace: " ns
                if [ -n "$ns" ]; then
                    create_limitrange "$ns"
                fi
                ;;
            5)
                read -p "Enter namespace (leave empty for all): " ns
                show_resource_usage "$ns"
                ;;
            6)
                read -p "Enter namespace (leave empty for all): " ns
                show_top_consumers "$ns"
                ;;
            7)
                check_pods_without_requests
                ;;
            8)
                read -p "Enter namespace (leave empty for all): " ns
                resource_audit "$ns"
                ;;
            9)
                print_info "Exiting"
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

    check_prerequisites

    case $1 in
        -h|--help)
            usage
            ;;
        quota-status)
            show_quota_status "${2:-}"
            ;;
        quota-create)
            if [ -z "${2:-}" ]; then
                print_error "Namespace is required"
                exit 1
            fi
            create_resource_quota "$2"
            ;;
        limitrange-status)
            show_limitrange_status "${2:-}"
            ;;
        limitrange-create)
            if [ -z "${2:-}" ]; then
                print_error "Namespace is required"
                exit 1
            fi
            create_limitrange "$2"
            ;;
        resource-usage)
            show_resource_usage "${2:-}"
            ;;
        top-consumers)
            show_top_consumers "${2:-}"
            ;;
        check-requests)
            check_pods_without_requests
            ;;
        audit)
            resource_audit "${2:-}"
            ;;
        interactive)
            interactive_mode
            ;;
        *)
            print_error "Unknown command: $1"
            usage
            ;;
    esac
}

main "$@"
