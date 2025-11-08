#!/usr/bin/env bash
#
# k8s-rbac-audit.sh - Kubernetes RBAC Auditing and Validation
# Based on official Kubernetes documentation:
# - https://kubernetes.io/docs/tasks/administer-cluster/
# - RBAC security and access control management
#
# This script helps audit and validate RBAC configurations

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
Kubernetes RBAC Auditing and Validation v${VERSION}

Usage: $(basename "$0") COMMAND [OPTIONS]

Commands:
    list-roles [namespace]          List all roles and cluster roles
    list-bindings [namespace]       List all role bindings
    user-permissions <user>         Show permissions for a user
    sa-permissions <sa> [ns]        Show permissions for a service account
    check-access <verb> <resource>  Check if current user can perform action
    audit [namespace]               Full RBAC audit
    find-privileged                 Find privileged service accounts
    unused-roles                    Find unused roles
    validate                        Validate RBAC configuration
    interactive                     Interactive RBAC management

Options:
    -n, --namespace <ns>    Kubernetes namespace
    -o, --output <file>     Output file for results
    -h, --help              Show this help message

Examples:
    # List all roles in a namespace
    $(basename "$0") list-roles -n production

    # Check user permissions
    $(basename "$0") user-permissions john@example.com

    # Check if current user can delete pods
    $(basename "$0") check-access delete pods

    # Full RBAC audit
    $(basename "$0") audit

    # Find privileged service accounts
    $(basename "$0") find-privileged

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

list_roles() {
    local namespace="${1:-}"

    print_header "RBAC Roles"

    if [ -z "$namespace" ]; then
        print_info "Cluster Roles:"
        kubectl get clusterroles
        echo ""

        print_info "Namespaced Roles (all namespaces):"
        kubectl get roles --all-namespaces
    else
        print_info "Roles in namespace: $namespace"
        kubectl get roles -n "$namespace"
        echo ""
        kubectl describe roles -n "$namespace"
    fi
}

list_bindings() {
    local namespace="${1:-}"

    print_header "RBAC Role Bindings"

    if [ -z "$namespace" ]; then
        print_info "Cluster Role Bindings:"
        kubectl get clusterrolebindings
        echo ""

        print_info "Namespaced Role Bindings (all namespaces):"
        kubectl get rolebindings --all-namespaces
    else
        print_info "Role Bindings in namespace: $namespace"
        kubectl get rolebindings -n "$namespace"
        echo ""
        kubectl describe rolebindings -n "$namespace"
    fi
}

show_user_permissions() {
    local user="$1"

    print_header "Permissions for User: $user"

    print_info "Cluster-wide permissions:"
    echo ""

    # Find ClusterRoleBindings for this user
    print_info "ClusterRoleBindings:"
    kubectl get clusterrolebindings -o json | jq -r --arg user "$user" '
        .items[] |
        select(.subjects[]?.name == $user) |
        "\(.metadata.name)\t\(.roleRef.name)"
    ' | while IFS=$'\t' read -r binding role; do
        if [ -n "$binding" ]; then
            echo "  Binding: $binding -> Role: $role"
            kubectl describe clusterrole "$role" 2>/dev/null | grep -A 10 "^PolicyRule:" || true
            echo ""
        fi
    done

    echo ""
    print_info "Namespace-specific permissions:"
    kubectl get rolebindings --all-namespaces -o json | jq -r --arg user "$user" '
        .items[] |
        select(.subjects[]?.name == $user) |
        "\(.metadata.namespace)\t\(.metadata.name)\t\(.roleRef.name)"
    ' | while IFS=$'\t' read -r ns binding role; do
        if [ -n "$binding" ]; then
            echo "  Namespace: $ns, Binding: $binding -> Role: $role"
        fi
    done

    echo ""
    print_info "Testing common permissions for user '$user':"
    local verbs=("get" "list" "create" "delete" "update")
    local resources=("pods" "services" "deployments" "secrets" "configmaps")

    for verb in "${verbs[@]}"; do
        for resource in "${resources[@]}"; do
            if kubectl auth can-i "$verb" "$resource" --as "$user" &> /dev/null; then
                print_success "Can $verb $resource"
            fi
        done
    done
}

show_sa_permissions() {
    local sa="$1"
    local namespace="${2:-default}"

    print_header "Permissions for ServiceAccount: $sa (namespace: $namespace)"

    # Check if SA exists
    if ! kubectl get sa "$sa" -n "$namespace" &> /dev/null; then
        print_error "ServiceAccount '$sa' not found in namespace '$namespace'"
        return 1
    fi

    print_info "ServiceAccount details:"
    kubectl describe sa "$sa" -n "$namespace"
    echo ""

    print_info "Cluster-wide permissions:"
    kubectl get clusterrolebindings -o json | jq -r --arg sa "$sa" --arg ns "$namespace" '
        .items[] |
        select(.subjects[]? | select(.kind == "ServiceAccount" and .name == $sa and .namespace == $ns)) |
        "\(.metadata.name)\t\(.roleRef.name)"
    ' | while IFS=$'\t' read -r binding role; do
        if [ -n "$binding" ]; then
            echo "  ClusterRoleBinding: $binding -> ClusterRole: $role"
            kubectl describe clusterrole "$role" 2>/dev/null | grep -A 10 "^PolicyRule:" || true
            echo ""
        fi
    done

    echo ""
    print_info "Namespace-specific permissions:"
    kubectl get rolebindings -n "$namespace" -o json | jq -r --arg sa "$sa" '
        .items[] |
        select(.subjects[]? | select(.kind == "ServiceAccount" and .name == $sa)) |
        "\(.metadata.name)\t\(.roleRef.name)\t\(.roleRef.kind)"
    ' | while IFS=$'\t' read -r binding role kind; do
        if [ -n "$binding" ]; then
            echo "  RoleBinding: $binding -> $kind: $role"
            if [ "$kind" = "Role" ]; then
                kubectl describe role "$role" -n "$namespace" 2>/dev/null | grep -A 10 "^PolicyRule:" || true
            else
                kubectl describe clusterrole "$role" 2>/dev/null | grep -A 10 "^PolicyRule:" || true
            fi
            echo ""
        fi
    done
}

check_access() {
    local verb="$1"
    local resource="$2"
    local namespace="${3:-}"

    print_header "Access Check"

    local cmd="kubectl auth can-i $verb $resource"
    [ -n "$namespace" ] && cmd="$cmd -n $namespace"

    print_info "Checking: Can current user '$verb' '$resource'?"
    [ -n "$namespace" ] && print_info "Namespace: $namespace"

    if eval "$cmd" &> /dev/null; then
        print_success "YES - Current user CAN $verb $resource"
        return 0
    else
        print_error "NO - Current user CANNOT $verb $resource"
        return 1
    fi
}

rbac_audit() {
    local namespace="${1:-}"

    print_header "RBAC Security Audit"

    echo ""
    print_info "=== Cluster Roles ==="
    kubectl get clusterroles | wc -l | xargs -I {} echo "Total ClusterRoles: {}"

    echo ""
    print_info "=== Cluster Role Bindings ==="
    kubectl get clusterrolebindings | wc -l | xargs -I {} echo "Total ClusterRoleBindings: {}"

    if [ -z "$namespace" ]; then
        echo ""
        print_info "=== Namespaced Roles (All Namespaces) ==="
        kubectl get roles --all-namespaces | wc -l | xargs -I {} echo "Total Roles: {}"

        echo ""
        print_info "=== Namespaced Role Bindings (All Namespaces) ==="
        kubectl get rolebindings --all-namespaces | wc -l | xargs -I {} echo "Total RoleBindings: {}"
    else
        echo ""
        print_info "=== Namespaced Roles in $namespace ==="
        kubectl get roles -n "$namespace"

        echo ""
        print_info "=== Namespaced Role Bindings in $namespace ==="
        kubectl get rolebindings -n "$namespace"
    fi

    echo ""
    print_info "=== Service Accounts ==="
    if [ -z "$namespace" ]; then
        kubectl get sa --all-namespaces | wc -l | xargs -I {} echo "Total ServiceAccounts: {}"
    else
        kubectl get sa -n "$namespace"
    fi

    echo ""
    print_info "=== Privileged ClusterRoleBindings ==="
    print_warning "ClusterRoleBindings granting cluster-admin:"
    kubectl get clusterrolebindings -o json | jq -r '
        .items[] |
        select(.roleRef.name == "cluster-admin") |
        "\(.metadata.name)\t\(.subjects[].kind)\t\(.subjects[].name)"
    ' | column -t

    echo ""
    print_warning "ClusterRoleBindings with wildcard permissions:"
    kubectl get clusterroles -o json | jq -r '
        .items[] |
        select(.rules[]? | select(.verbs[]? == "*" or .resources[]? == "*")) |
        .metadata.name
    ' | while read role; do
        if [ -n "$role" ]; then
            kubectl get clusterrolebindings -o json | jq -r --arg role "$role" '
                .items[] |
                select(.roleRef.name == $role) |
                "\(.metadata.name)\t\(.roleRef.name)"
            ' | while IFS=$'\t' read -r binding rolename; do
                [ -n "$binding" ] && echo "  $binding -> $rolename"
            done
        fi
    done

    echo ""
    print_success "RBAC audit completed"
}

find_privileged_sa() {
    print_header "Privileged Service Accounts"

    print_info "Service Accounts with cluster-admin access:"
    kubectl get clusterrolebindings -o json | jq -r '
        .items[] |
        select(.roleRef.name == "cluster-admin" and .subjects[]?.kind == "ServiceAccount") |
        "\(.metadata.name)\t\(.subjects[].namespace)\t\(.subjects[].name)"
    ' | column -t

    echo ""
    print_info "Service Accounts with edit/admin access:"
    kubectl get rolebindings --all-namespaces -o json | jq -r '
        .items[] |
        select((.roleRef.name == "admin" or .roleRef.name == "edit") and .subjects[]?.kind == "ServiceAccount") |
        "\(.metadata.namespace)\t\(.metadata.name)\t\(.roleRef.name)\t\(.subjects[].name)"
    ' | column -t

    echo ""
    print_info "Service Accounts with secrets access:"
    kubectl get rolebindings --all-namespaces -o json | jq -r '
        .items[] |
        select(.subjects[]?.kind == "ServiceAccount") |
        .metadata.namespace as $ns |
        .metadata.name as $binding |
        .roleRef.name as $role |
        .subjects[] | select(.kind == "ServiceAccount") |
        "\($ns)\t\($binding)\t\($role)\t\(.name)"
    ' | while IFS=$'\t' read -r ns binding role sa; do
        if [ -n "$sa" ]; then
            # Check if role grants access to secrets
            if kubectl get role "$role" -n "$ns" -o json 2>/dev/null | jq -e '.rules[] | select(.resources[] == "secrets")' &> /dev/null; then
                echo "$ns    $binding    $role    $sa"
            fi
        fi
    done | column -t
}

find_unused_roles() {
    print_header "Potentially Unused Roles"

    print_info "Scanning for roles without bindings..."
    echo ""

    # Check ClusterRoles
    print_info "ClusterRoles without ClusterRoleBindings:"
    local all_clusterroles=$(kubectl get clusterroles -o jsonpath='{.items[*].metadata.name}')
    local bound_clusterroles=$(kubectl get clusterrolebindings -o jsonpath='{.items[*].roleRef.name}')

    for role in $all_clusterroles; do
        if ! echo "$bound_clusterroles" | grep -q "\\b$role\\b"; then
            # Also check if used in RoleBindings
            if ! kubectl get rolebindings --all-namespaces -o jsonpath='{.items[*].roleRef.name}' | grep -q "\\b$role\\b"; then
                # Exclude system roles
                if [[ ! "$role" =~ ^system: ]]; then
                    echo "  $role"
                fi
            fi
        fi
    done

    echo ""
    print_info "Namespaced Roles without RoleBindings:"
    kubectl get roles --all-namespaces -o json | jq -r '
        .items[] |
        "\(.metadata.namespace)\t\(.metadata.name)"
    ' | while IFS=$'\t' read -r ns role; do
        if [ -n "$role" ]; then
            if ! kubectl get rolebindings -n "$ns" -o jsonpath='{.items[*].roleRef.name}' | grep -q "\\b$role\\b"; then
                echo "  $ns/$role"
            fi
        fi
    done
}

validate_rbac() {
    print_header "RBAC Configuration Validation"

    local issues=0

    print_info "Checking for common RBAC issues..."
    echo ""

    # Check 1: Default service accounts with elevated permissions
    print_info "[1] Checking for default service accounts with elevated permissions..."
    local default_sa_bindings=$(kubectl get rolebindings --all-namespaces -o json | jq -r '
        .items[] |
        select(.subjects[]? | select(.kind == "ServiceAccount" and .name == "default")) |
        "\(.metadata.namespace)\t\(.metadata.name)"
    ')

    if [ -n "$default_sa_bindings" ]; then
        print_warning "Default service accounts found with role bindings:"
        echo "$default_sa_bindings" | column -t
        ((issues++))
    else
        print_success "No default service accounts with role bindings found"
    fi

    echo ""

    # Check 2: Overly permissive roles
    print_info "[2] Checking for roles with wildcard (*) permissions..."
    local wildcard_roles=$(kubectl get clusterroles -o json | jq -r '
        .items[] |
        select(.rules[]? | select(.verbs[]? == "*" and .resources[]? == "*")) |
        .metadata.name
    ')

    if [ -n "$wildcard_roles" ]; then
        print_warning "Roles with wildcard permissions found:"
        echo "$wildcard_roles" | grep -v "^cluster-admin$" | grep -v "^system:" || true
        ((issues++))
    else
        print_success "No overly permissive custom roles found"
    fi

    echo ""

    # Check 3: Service accounts without automountServiceAccountToken: false
    print_info "[3] Checking for service accounts with auto-mounted tokens..."
    print_info "(Pods not using service accounts should disable auto-mounting)"
    local auto_mount_sa=$(kubectl get sa --all-namespaces -o json | jq -r '
        .items[] |
        select(.automountServiceAccountToken != false) |
        "\(.metadata.namespace)\t\(.metadata.name)"
    ' | head -n 10)

    if [ -n "$auto_mount_sa" ]; then
        print_warning "Service accounts with auto-mount enabled (showing first 10):"
        echo "$auto_mount_sa" | column -t
        print_info "Consider setting automountServiceAccountToken: false for unused service accounts"
    fi

    echo ""

    # Check 4: Cluster-admin bindings to users/groups
    print_info "[4] Checking cluster-admin bindings..."
    local cluster_admin_bindings=$(kubectl get clusterrolebindings -o json | jq -r '
        .items[] |
        select(.roleRef.name == "cluster-admin" and (.subjects[]?.kind == "User" or .subjects[]?.kind == "Group")) |
        "\(.metadata.name)\t\(.subjects[].kind)\t\(.subjects[].name)"
    ')

    if [ -n "$cluster_admin_bindings" ]; then
        print_warning "cluster-admin bindings to users/groups:"
        echo "$cluster_admin_bindings" | column -t
        print_info "Review these bindings to ensure they are necessary"
        ((issues++))
    else
        print_success "No cluster-admin bindings to users/groups"
    fi

    echo ""
    if [ $issues -eq 0 ]; then
        print_success "No critical RBAC issues found"
    else
        print_warning "Found $issues potential RBAC issues to review"
    fi
}

interactive_mode() {
    print_header "Interactive RBAC Management"

    while true; do
        echo ""
        echo "What would you like to do?"
        echo "1) List roles"
        echo "2) List role bindings"
        echo "3) Check user permissions"
        echo "4) Check service account permissions"
        echo "5) Check access for current user"
        echo "6) Full RBAC audit"
        echo "7) Find privileged service accounts"
        echo "8) Find unused roles"
        echo "9) Validate RBAC configuration"
        echo "10) Exit"
        echo ""
        read -p "Select an option (1-10): " choice

        case $choice in
            1)
                read -p "Enter namespace (leave empty for all): " ns
                list_roles "$ns"
                ;;
            2)
                read -p "Enter namespace (leave empty for all): " ns
                list_bindings "$ns"
                ;;
            3)
                read -p "Enter username: " user
                if [ -n "$user" ]; then
                    show_user_permissions "$user"
                fi
                ;;
            4)
                read -p "Enter service account name: " sa
                read -p "Enter namespace (default: default): " ns
                ns=${ns:-default}
                if [ -n "$sa" ]; then
                    show_sa_permissions "$sa" "$ns"
                fi
                ;;
            5)
                read -p "Enter verb (e.g., get, list, create, delete): " verb
                read -p "Enter resource (e.g., pods, services): " resource
                read -p "Enter namespace (optional): " ns
                if [ -n "$verb" ] && [ -n "$resource" ]; then
                    check_access "$verb" "$resource" "$ns"
                fi
                ;;
            6)
                read -p "Enter namespace (leave empty for cluster-wide): " ns
                rbac_audit "$ns"
                ;;
            7)
                find_privileged_sa
                ;;
            8)
                find_unused_roles
                ;;
            9)
                validate_rbac
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

    check_prerequisites

    case $1 in
        -h|--help)
            usage
            ;;
        list-roles)
            list_roles "${2:-}"
            ;;
        list-bindings)
            list_bindings "${2:-}"
            ;;
        user-permissions)
            if [ -z "${2:-}" ]; then
                print_error "Username is required"
                exit 1
            fi
            show_user_permissions "$2"
            ;;
        sa-permissions)
            if [ -z "${2:-}" ]; then
                print_error "Service account name is required"
                exit 1
            fi
            show_sa_permissions "$2" "${3:-default}"
            ;;
        check-access)
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                print_error "Verb and resource are required"
                exit 1
            fi
            check_access "$2" "$3" "${4:-}"
            ;;
        audit)
            rbac_audit "${2:-}"
            ;;
        find-privileged)
            find_privileged_sa
            ;;
        unused-roles)
            find_unused_roles
            ;;
        validate)
            validate_rbac
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
