#!/usr/bin/env bash
# Interactive Kubernetes Resource Generator Wizard
# This script provides an interactive interface to generate Kubernetes resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/k8s-resource-generator.sh"
EXAMPLES_DIR="$(cd "$SCRIPT_DIR/../.k8s-templates/examples" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")

    echo -e "${YELLOW}${prompt}${NC}"
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done

    local choice
    while true; do
        read -rp "Enter choice [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        echo -e "${RED}Invalid choice. Please try again.${NC}"
    done
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt}${NC}") [${default}]: " value
        echo "${value:-$default}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt}${NC}"): " value
        echo "$value"
    fi
}

prompt_multiline() {
    local prompt="$1"
    echo -e "${YELLOW}${prompt}${NC}"
    echo -e "${BLUE}(Enter multi-line input. Press Ctrl+D when done)${NC}"
    cat
}

# Main wizard
main() {
    log_header "Kubernetes Resource Generator - Interactive Wizard"

    # Step 1: Choose template type
    local template_type
    template_type=$(prompt_choice "Select resource type:" \
        "ArgoCD Application (Directory Source)" \
        "ArgoCD Application (Helm Chart)" \
        "ArgoCD Application (Multi-Source)" \
        "Deployment + Service" \
        "ConfigMap" \
        "ExternalSecret" \
        "Ingress" \
        "CronJob" \
        "PersistentVolumeClaim" \
        "Namespace" \
        "ServiceAccount + RBAC" \
        "Use Example Config File")

    case "$template_type" in
        "ArgoCD Application (Directory Source)")
            template_type="argocd-app-directory"
            ;;
        "ArgoCD Application (Helm Chart)")
            template_type="argocd-app-helm"
            ;;
        "ArgoCD Application (Multi-Source)")
            template_type="argocd-app-multisource"
            ;;
        "Deployment + Service")
            template_type="deployment-service"
            ;;
        "ConfigMap")
            template_type="configmap"
            ;;
        "ExternalSecret")
            template_type="externalsecret"
            ;;
        "Ingress")
            template_type="ingress"
            ;;
        "CronJob")
            template_type="cronjob"
            ;;
        "PersistentVolumeClaim")
            template_type="pvc"
            ;;
        "Namespace")
            template_type="namespace"
            ;;
        "ServiceAccount + RBAC")
            template_type="serviceaccount-rbac"
            ;;
        "Use Example Config File")
            use_example_config
            return 0
            ;;
    esac

    log_header "Gathering Configuration for: $template_type"

    # Step 2: Create config file
    local config_file
    config_file=$(mktemp /tmp/k8s-config.XXXXXX.yaml)

    # Get required fields based on template type
    case "$template_type" in
        argocd-app-*)
            create_argocd_config "$template_type" "$config_file"
            ;;
        deployment-service)
            create_deployment_config "$config_file"
            ;;
        configmap)
            create_configmap_config "$config_file"
            ;;
        externalsecret)
            create_externalsecret_config "$config_file"
            ;;
        cronjob)
            create_cronjob_config "$config_file"
            ;;
        pvc)
            create_pvc_config "$config_file"
            ;;
        namespace)
            create_namespace_config "$config_file"
            ;;
        *)
            log_info "Using basic configuration template"
            create_basic_config "$config_file"
            ;;
    esac

    # Step 3: Preview configuration
    log_header "Configuration Preview"
    cat "$config_file"

    # Step 4: Confirm
    echo ""
    read -rp "$(echo -e "${YELLOW}Generate resource with this configuration?${NC}") [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_info "Cancelled. Config saved to: $config_file"
        exit 0
    fi

    # Step 5: Generate
    log_header "Generating Resource"

    local validate=""
    read -rp "$(echo -e "${YELLOW}Validate with kubectl?${NC}") [Y/n]: " validate_choice
    if [[ ! "$validate_choice" =~ ^[Nn] ]]; then
        validate="-v"
    fi

    "$GENERATOR" $validate "$template_type" "$config_file"

    # Cleanup
    rm -f "$config_file"

    log_success "Resource generated successfully!"
}

# Configuration creators
create_argocd_config() {
    local type="$1"
    local config_file="$2"

    local app_name namespace project source_path

    app_name=$(prompt_input "Application name")
    namespace=$(prompt_input "Target namespace" "default")
    project=$(prompt_input "ArgoCD project" "applications")

    {
        echo "app_name: $app_name"
        echo "namespace: $namespace"
        echo "project: $project"
    } > "$config_file"

    if [[ "$type" == "argocd-app-directory" ]]; then
        source_path=$(prompt_input "Source path in repository" "gitops/apps/$app_name")
        echo "source_path: $source_path" >> "$config_file"
    elif [[ "$type" == "argocd-app-helm" ]]; then
        local chart_name chart_repo chart_version
        chart_name=$(prompt_input "Helm chart name")
        chart_repo=$(prompt_input "Helm chart repository URL")
        chart_version=$(prompt_input "Chart version")
        {
            echo "chart_name: $chart_name"
            echo "chart_repo_url: $chart_repo"
            echo "chart_version: $chart_version"
        } >> "$config_file"
    fi
}

create_deployment_config() {
    local config_file="$1"

    local app_name image namespace replicas container_port

    app_name=$(prompt_input "Application name")
    image=$(prompt_input "Container image" "nginx:latest")
    namespace=$(prompt_input "Namespace" "default")
    replicas=$(prompt_input "Number of replicas" "1")
    container_port=$(prompt_input "Container port" "80")

    {
        echo "app_name: $app_name"
        echo "image: $image"
        echo "namespace: $namespace"
        echo "replicas: $replicas"
        echo "container_port: $container_port"
    } > "$config_file"

    read -rp "$(echo -e "${YELLOW}Create LoadBalancer service?${NC}") [y/N]: " lb_choice
    if [[ "$lb_choice" =~ ^[Yy] ]]; then
        echo "service_type: LoadBalancer" >> "$config_file"
        local lb_ip
        lb_ip=$(prompt_input "LoadBalancer IP (optional)")
        if [[ -n "$lb_ip" ]]; then
            echo "load_balancer_ip: $lb_ip" >> "$config_file"
        fi
    fi
}

create_configmap_config() {
    local config_file="$1"

    local name namespace
    name=$(prompt_input "ConfigMap name")
    namespace=$(prompt_input "Namespace" "default")

    {
        echo "configmap_name: $name"
        echo "namespace: $namespace"
        echo "data: |"
        echo "  config.yaml: |"
        echo "    # Add your configuration here"
    } > "$config_file"
}

create_externalsecret_config() {
    local config_file="$1"

    local name namespace
    name=$(prompt_input "Secret name")
    namespace=$(prompt_input "Namespace" "default")

    {
        echo "secret_name: $name"
        echo "namespace: $namespace"
        echo "secret_data: |"
        echo "  - secretKey: key1"
        echo "    remoteRef:"
        echo "      key: remote-key-id"
        echo "      property: value"
    } > "$config_file"
}

create_cronjob_config() {
    local config_file="$1"

    local name schedule image namespace
    name=$(prompt_input "CronJob name")
    schedule=$(prompt_input "Schedule (cron format)" "0 2 * * *")
    image=$(prompt_input "Container image" "alpine:latest")
    namespace=$(prompt_input "Namespace" "default")

    {
        echo "cronjob_name: $name"
        echo "schedule: \"$schedule\""
        echo "image: $image"
        echo "namespace: $namespace"
        echo "command: '[\"/bin/sh\", \"-c\"]'"
        echo "args: |"
        echo "  - |"
        echo "    echo \"Job running at \$(date)\""
    } > "$config_file"
}

create_pvc_config() {
    local config_file="$1"

    local name namespace size storage_class
    name=$(prompt_input "PVC name")
    namespace=$(prompt_input "Namespace" "default")
    size=$(prompt_input "Storage size" "1Gi")
    storage_class=$(prompt_input "Storage class" "local-path")

    {
        echo "pvc_name: $name"
        echo "namespace: $namespace"
        echo "storage_size: $size"
        echo "storage_class: $storage_class"
    } > "$config_file"
}

create_namespace_config() {
    local config_file="$1"

    local name
    name=$(prompt_input "Namespace name")

    echo "namespace_name: $name" > "$config_file"
}

create_basic_config() {
    local config_file="$1"

    echo "# Add your configuration here" > "$config_file"
    echo "# Refer to examples in .k8s-templates/examples/" >> "$config_file"
}

use_example_config() {
    log_header "Available Example Configurations"

    local examples=()
    while IFS= read -r -d '' file; do
        examples+=("$(basename "$file")")
    done < <(find "$EXAMPLES_DIR" -maxdepth 1 -name "*.yaml" -print0 2>/dev/null)

    if [[ ${#examples[@]} -eq 0 ]]; then
        log_info "No example configurations found"
        exit 1
    fi

    local example
    example=$(prompt_choice "Select example:" "${examples[@]}")

    local example_path="${EXAMPLES_DIR}/${example}"

    log_info "Example configuration:"
    cat "$example_path"

    echo ""
    read -rp "$(echo -e "${YELLOW}Generate resource from this example?${NC}") [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        exit 0
    fi

    # Determine template type from example filename
    local template_type
    template_type=$(basename "$example" -example.yaml)

    "$GENERATOR" -v "$template_type" "$example_path"
}

# Run main
main "$@"
