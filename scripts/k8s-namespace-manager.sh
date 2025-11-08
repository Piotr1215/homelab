#!/usr/bin/env bash
#
# k8s-namespace-manager.sh - Kubernetes Namespace Management and Cleanup
# Based on official Kubernetes documentation:
# - https://kubernetes.io/docs/tasks/administer-cluster/
# - Namespace management best practices
#
# This script helps manage and clean up Kubernetes namespaces

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
Kubernetes Namespace Management and Cleanup v${VERSION}

Usage: $(basename "$0") COMMAND [OPTIONS]

Commands:
    list                        List all namespaces with details
    create <name>               Create a new namespace with best practices
    delete <name>               Safely delete a namespace
    cleanup <name>              Clean up resources in a namespace
    empty-check <name>          Check if namespace is empty
    find-empty                  Find all empty namespaces
    resource-summary [name]     Show resource summary
    compare <ns1> <ns2>         Compare two namespaces
    export <name> <dir>         Export namespace resources to directory
    interactive                 Interactive namespace management

Options:
    -f, --force                 Force operation without confirmation
    -d, --dry-run               Show what would be done without executing
    -h, --help                  Show this help message

Examples:
    # List all namespaces
    $(basename "$0") list

    # Create a new namespace with labels
    $(basename "$0") create development

    # Find empty namespaces
    $(basename "$0") find-empty

    # Clean up resources in a namespace
    $(basename "$0") cleanup old-project

    # Export namespace resources
    $(basename "$0") export production /tmp/backup

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

list_namespaces() {
    print_header "Kubernetes Namespaces"

    print_info "All Namespaces:"
    kubectl get namespaces -o wide

    echo ""
    print_info "Namespace Details:"
    echo ""
    printf "%-30s %-15s %-10s %-10s %-10s\n" "NAMESPACE" "STATUS" "PODS" "SERVICES" "SECRETS"
    printf "%-30s %-15s %-10s %-10s %-10s\n" "----------" "------" "----" "--------" "-------"

    kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read ns; do
        local status=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}')
        local pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        local services=$(kubectl get services -n "$ns" --no-headers 2>/dev/null | wc -l)
        local secrets=$(kubectl get secrets -n "$ns" --no-headers 2>/dev/null | wc -l)

        printf "%-30s %-15s %-10s %-10s %-10s\n" "$ns" "$status" "$pods" "$services" "$secrets"
    done
}

create_namespace() {
    local name="$1"
    local force="${2:-false}"

    print_header "Create Namespace: $name"

    # Check if namespace already exists
    if kubectl get namespace "$name" &> /dev/null; then
        print_error "Namespace '$name' already exists"
        return 1
    fi

    # Validate namespace name
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        print_error "Invalid namespace name. Must be lowercase alphanumeric with hyphens."
        return 1
    fi

    echo ""
    print_info "Creating namespace with best practices..."

    # Interactive labels
    if [ "$force" = "false" ]; then
        read -p "Enter environment (e.g., dev, staging, prod): " env
        read -p "Enter team/owner: " owner
        read -p "Enter description: " description
    fi

    # Build namespace YAML
    local ns_yaml="apiVersion: v1
kind: Namespace
metadata:
  name: ${name}"

    if [ -n "${env:-}" ] || [ -n "${owner:-}" ]; then
        ns_yaml="${ns_yaml}
  labels:"
        [ -n "${env:-}" ] && ns_yaml="${ns_yaml}
    environment: ${env}"
        [ -n "${owner:-}" ] && ns_yaml="${ns_yaml}
    owner: ${owner}"
    fi

    if [ -n "${description:-}" ]; then
        ns_yaml="${ns_yaml}
  annotations:
    description: \"${description}\""
    fi

    echo ""
    print_info "Namespace YAML:"
    echo "$ns_yaml"
    echo ""

    if [ "$force" = "false" ]; then
        read -p "Create this namespace? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            print_info "Namespace creation cancelled"
            return 0
        fi
    fi

    echo "$ns_yaml" | kubectl apply -f -
    print_success "Namespace '$name' created"

    # Ask about resource quota and limit range
    if [ "$force" = "false" ]; then
        echo ""
        read -p "Would you like to set up resource quotas? (y/n): " setup_quota
        if [ "$setup_quota" = "y" ]; then
            print_info "Use k8s-resource-manager.sh to set up resource quotas"
            print_info "Example: k8s-resource-manager.sh quota-create $name"
        fi

        read -p "Would you like to set up limit ranges? (y/n): " setup_limits
        if [ "$setup_limits" = "y" ]; then
            print_info "Use k8s-resource-manager.sh to set up limit ranges"
            print_info "Example: k8s-resource-manager.sh limitrange-create $name"
        fi
    fi
}

delete_namespace() {
    local name="$1"
    local force="${2:-false}"

    print_header "Delete Namespace: $name"

    # Check if namespace exists
    if ! kubectl get namespace "$name" &> /dev/null; then
        print_error "Namespace '$name' does not exist"
        return 1
    fi

    # Prevent deletion of system namespaces
    if [[ "$name" =~ ^(default|kube-system|kube-public|kube-node-lease)$ ]]; then
        print_error "Cannot delete system namespace: $name"
        return 1
    fi

    # Show what will be deleted
    print_warning "Resources in namespace '$name' that will be deleted:"
    echo ""
    kubectl get all -n "$name" 2>/dev/null || print_info "No resources found"

    echo ""
    local pvc_count=$(kubectl get pvc -n "$name" --no-headers 2>/dev/null | wc -l)
    if [ "$pvc_count" -gt 0 ]; then
        print_warning "Persistent Volume Claims: $pvc_count"
        kubectl get pvc -n "$name"
        echo ""
        print_warning "Deleting the namespace will also delete these PVCs!"
    fi

    echo ""
    if [ "$force" = "false" ]; then
        print_warning "This action cannot be undone!"
        read -p "Type the namespace name to confirm deletion: " confirm
        if [ "$confirm" != "$name" ]; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    print_info "Deleting namespace '$name'..."
    kubectl delete namespace "$name"

    print_success "Namespace '$name' deleted"
}

cleanup_namespace() {
    local name="$1"
    local force="${2:-false}"

    print_header "Cleanup Namespace: $name"

    # Check if namespace exists
    if ! kubectl get namespace "$name" &> /dev/null; then
        print_error "Namespace '$name' does not exist"
        return 1
    fi

    print_info "Analyzing resources in namespace '$name'..."
    echo ""

    # Find failed/completed pods
    local failed_pods=$(kubectl get pods -n "$name" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
    local succeeded_pods=$(kubectl get pods -n "$name" --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l)

    if [ "$failed_pods" -gt 0 ]; then
        print_info "Failed pods: $failed_pods"
        kubectl get pods -n "$name" --field-selector=status.phase=Failed
        echo ""
        if [ "$force" = "false" ]; then
            read -p "Delete failed pods? (y/n): " delete_failed
            if [ "$delete_failed" = "y" ]; then
                kubectl delete pods -n "$name" --field-selector=status.phase=Failed
                print_success "Failed pods deleted"
            fi
        else
            kubectl delete pods -n "$name" --field-selector=status.phase=Failed
            print_success "Failed pods deleted"
        fi
    fi

    if [ "$succeeded_pods" -gt 0 ]; then
        echo ""
        print_info "Completed pods: $succeeded_pods"
        kubectl get pods -n "$name" --field-selector=status.phase=Succeeded
        echo ""
        if [ "$force" = "false" ]; then
            read -p "Delete completed pods? (y/n): " delete_completed
            if [ "$delete_completed" = "y" ]; then
                kubectl delete pods -n "$name" --field-selector=status.phase=Succeeded
                print_success "Completed pods deleted"
            fi
        else
            kubectl delete pods -n "$name" --field-selector=status.phase=Succeeded
            print_success "Completed pods deleted"
        fi
    fi

    # Find evicted pods
    echo ""
    local evicted_pods=$(kubectl get pods -n "$name" --no-headers 2>/dev/null | grep "Evicted" | wc -l)
    if [ "$evicted_pods" -gt 0 ]; then
        print_info "Evicted pods: $evicted_pods"
        kubectl get pods -n "$name" | grep "Evicted"
        echo ""
        if [ "$force" = "false" ]; then
            read -p "Delete evicted pods? (y/n): " delete_evicted
            if [ "$delete_evicted" = "y" ]; then
                kubectl get pods -n "$name" --no-headers | grep "Evicted" | awk '{print $1}' | xargs -r kubectl delete pod -n "$name"
                print_success "Evicted pods deleted"
            fi
        else
            kubectl get pods -n "$name" --no-headers | grep "Evicted" | awk '{print $1}' | xargs -r kubectl delete pod -n "$name"
            print_success "Evicted pods deleted"
        fi
    fi

    # Find old replica sets
    echo ""
    print_info "Checking for old ReplicaSets..."
    local old_rs=$(kubectl get rs -n "$name" --no-headers 2>/dev/null | awk '$2 == 0 && $3 == 0 && $4 == 0' | wc -l)
    if [ "$old_rs" -gt 0 ]; then
        print_info "Old ReplicaSets (0 desired, 0 current): $old_rs"
        kubectl get rs -n "$name" | awk 'NR==1 || ($2 == 0 && $3 == 0 && $4 == 0)'
        echo ""
        if [ "$force" = "false" ]; then
            read -p "Delete old ReplicaSets? (y/n): " delete_rs
            if [ "$delete_rs" = "y" ]; then
                kubectl get rs -n "$name" --no-headers | awk '$2 == 0 && $3 == 0 && $4 == 0 {print $1}' | xargs -r kubectl delete rs -n "$name"
                print_success "Old ReplicaSets deleted"
            fi
        else
            kubectl get rs -n "$name" --no-headers | awk '$2 == 0 && $3 == 0 && $4 == 0 {print $1}' | xargs -r kubectl delete rs -n "$name"
            print_success "Old ReplicaSets deleted"
        fi
    fi

    echo ""
    print_success "Cleanup completed for namespace '$name'"
}

check_if_empty() {
    local name="$1"

    print_header "Empty Check: $name"

    # Check if namespace exists
    if ! kubectl get namespace "$name" &> /dev/null; then
        print_error "Namespace '$name' does not exist"
        return 1
    fi

    local is_empty=true

    # Check various resource types
    local pods=$(kubectl get pods -n "$name" --no-headers 2>/dev/null | wc -l)
    local services=$(kubectl get services -n "$name" --no-headers 2>/dev/null | wc -l)
    local deployments=$(kubectl get deployments -n "$name" --no-headers 2>/dev/null | wc -l)
    local statefulsets=$(kubectl get statefulsets -n "$name" --no-headers 2>/dev/null | wc -l)
    local daemonsets=$(kubectl get daemonsets -n "$name" --no-headers 2>/dev/null | wc -l)
    local configmaps=$(kubectl get configmaps -n "$name" --no-headers 2>/dev/null | wc -l)
    local secrets=$(kubectl get secrets -n "$name" --no-headers 2>/dev/null | wc -l)
    local pvcs=$(kubectl get pvc -n "$name" --no-headers 2>/dev/null | wc -l)

    echo "Resource Count:"
    echo "  Pods: $pods"
    echo "  Services: $services"
    echo "  Deployments: $deployments"
    echo "  StatefulSets: $statefulsets"
    echo "  DaemonSets: $daemonsets"
    echo "  ConfigMaps: $configmaps"
    echo "  Secrets: $secrets"
    echo "  PVCs: $pvcs"

    if [ "$pods" -gt 0 ] || [ "$services" -gt 0 ] || [ "$deployments" -gt 0 ] || \
       [ "$statefulsets" -gt 0 ] || [ "$daemonsets" -gt 0 ] || [ "$configmaps" -gt 0 ] || \
       [ "$secrets" -gt 0 ] || [ "$pvcs" -gt 0 ]; then
        is_empty=false
    fi

    echo ""
    if [ "$is_empty" = true ]; then
        print_success "Namespace '$name' is EMPTY"
    else
        print_info "Namespace '$name' is NOT empty"
    fi
}

find_empty_namespaces() {
    print_header "Empty Namespaces"

    print_info "Scanning for empty namespaces..."
    echo ""

    local empty_namespaces=()

    kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read ns; do
        # Skip system namespaces
        if [[ "$ns" =~ ^(default|kube-system|kube-public|kube-node-lease)$ ]]; then
            continue
        fi

        local pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        local all_resources=$(kubectl get all -n "$ns" --no-headers 2>/dev/null | wc -l)

        if [ "$pods" -eq 0 ] && [ "$all_resources" -eq 0 ]; then
            echo "$ns"
        fi
    done

    echo ""
    print_info "Empty namespaces can be safely deleted if no longer needed"
}

resource_summary() {
    local name="${1:-}"

    if [ -z "$name" ]; then
        print_header "Resource Summary (All Namespaces)"

        kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read ns; do
            echo ""
            print_info "Namespace: $ns"
            kubectl get all -n "$ns" --no-headers 2>/dev/null | wc -l | xargs -I {} echo "  Total resources: {}"
        done
    else
        print_header "Resource Summary: $name"

        if ! kubectl get namespace "$name" &> /dev/null; then
            print_error "Namespace '$name' does not exist"
            return 1
        fi

        kubectl get all -n "$name"
        echo ""
        kubectl get configmaps,secrets,pvc -n "$name"
    fi
}

compare_namespaces() {
    local ns1="$1"
    local ns2="$2"

    print_header "Compare Namespaces: $ns1 vs $ns2"

    # Check if both exist
    if ! kubectl get namespace "$ns1" &> /dev/null; then
        print_error "Namespace '$ns1' does not exist"
        return 1
    fi

    if ! kubectl get namespace "$ns2" &> /dev/null; then
        print_error "Namespace '$ns2' does not exist"
        return 1
    fi

    echo ""
    printf "%-20s %-15s %-15s\n" "RESOURCE" "$ns1" "$ns2"
    printf "%-20s %-15s %-15s\n" "--------" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..15})"

    # Compare various resources
    local resources=("pods" "services" "deployments" "statefulsets" "daemonsets" "configmaps" "secrets" "pvc")

    for resource in "${resources[@]}"; do
        local count1=$(kubectl get "$resource" -n "$ns1" --no-headers 2>/dev/null | wc -l)
        local count2=$(kubectl get "$resource" -n "$ns2" --no-headers 2>/dev/null | wc -l)
        printf "%-20s %-15s %-15s\n" "$resource" "$count1" "$count2"
    done
}

export_namespace() {
    local name="$1"
    local output_dir="$2"

    print_header "Export Namespace: $name"

    # Check if namespace exists
    if ! kubectl get namespace "$name" &> /dev/null; then
        print_error "Namespace '$name' does not exist"
        return 1
    fi

    # Create output directory
    mkdir -p "$output_dir"

    print_info "Exporting namespace resources to $output_dir..."

    # Export namespace definition
    kubectl get namespace "$name" -o yaml > "$output_dir/namespace.yaml"

    # Export all resource types
    local resources=("pods" "services" "deployments" "statefulsets" "daemonsets" "replicasets" "configmaps" "secrets" "pvc" "ingress" "serviceaccounts" "roles" "rolebindings")

    for resource in "${resources[@]}"; do
        local count=$(kubectl get "$resource" -n "$name" --no-headers 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            print_info "Exporting $resource ($count items)..."
            kubectl get "$resource" -n "$name" -o yaml > "$output_dir/${resource}.yaml"
        fi
    done

    print_success "Namespace exported to $output_dir"
    ls -lh "$output_dir"
}

interactive_mode() {
    print_header "Interactive Namespace Management"

    while true; do
        echo ""
        echo "What would you like to do?"
        echo "1) List namespaces"
        echo "2) Create namespace"
        echo "3) Delete namespace"
        echo "4) Cleanup namespace"
        echo "5) Check if namespace is empty"
        echo "6) Find empty namespaces"
        echo "7) Resource summary"
        echo "8) Compare namespaces"
        echo "9) Export namespace"
        echo "10) Exit"
        echo ""
        read -p "Select an option (1-10): " choice

        case $choice in
            1)
                list_namespaces
                ;;
            2)
                read -p "Enter namespace name: " name
                if [ -n "$name" ]; then
                    create_namespace "$name"
                fi
                ;;
            3)
                read -p "Enter namespace name: " name
                if [ -n "$name" ]; then
                    delete_namespace "$name"
                fi
                ;;
            4)
                read -p "Enter namespace name: " name
                if [ -n "$name" ]; then
                    cleanup_namespace "$name"
                fi
                ;;
            5)
                read -p "Enter namespace name: " name
                if [ -n "$name" ]; then
                    check_if_empty "$name"
                fi
                ;;
            6)
                find_empty_namespaces
                ;;
            7)
                read -p "Enter namespace name (leave empty for all): " name
                resource_summary "$name"
                ;;
            8)
                read -p "Enter first namespace: " ns1
                read -p "Enter second namespace: " ns2
                if [ -n "$ns1" ] && [ -n "$ns2" ]; then
                    compare_namespaces "$ns1" "$ns2"
                fi
                ;;
            9)
                read -p "Enter namespace name: " name
                read -p "Enter output directory: " dir
                if [ -n "$name" ] && [ -n "$dir" ]; then
                    export_namespace "$name" "$dir"
                fi
                ;;
            10)
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

    local force=false

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                break
                ;;
        esac
    done

    check_prerequisites

    case ${1:-} in
        list)
            list_namespaces
            ;;
        create)
            if [ -z "${2:-}" ]; then
                print_error "Namespace name is required"
                exit 1
            fi
            create_namespace "$2" "$force"
            ;;
        delete)
            if [ -z "${2:-}" ]; then
                print_error "Namespace name is required"
                exit 1
            fi
            delete_namespace "$2" "$force"
            ;;
        cleanup)
            if [ -z "${2:-}" ]; then
                print_error "Namespace name is required"
                exit 1
            fi
            cleanup_namespace "$2" "$force"
            ;;
        empty-check)
            if [ -z "${2:-}" ]; then
                print_error "Namespace name is required"
                exit 1
            fi
            check_if_empty "$2"
            ;;
        find-empty)
            find_empty_namespaces
            ;;
        resource-summary)
            resource_summary "${2:-}"
            ;;
        compare)
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                print_error "Two namespace names are required"
                exit 1
            fi
            compare_namespaces "$2" "$3"
            ;;
        export)
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                print_error "Namespace name and output directory are required"
                exit 1
            fi
            export_namespace "$2" "$3"
            ;;
        interactive)
            interactive_mode
            ;;
        *)
            print_error "Unknown command: ${1:-}"
            usage
            ;;
    esac
}

main "$@"
