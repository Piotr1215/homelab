#!/usr/bin/env bash
# Kubernetes Resource Generator - MCP-style Template System
# This script generates Kubernetes resources from templates with variable substitution

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/.k8s-templates"
DEFAULT_OUTPUT_DIR="${REPO_ROOT}/gitops"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Usage information
usage() {
    cat <<EOF
Kubernetes Resource Generator

USAGE:
    $(basename "$0") [OPTIONS] <template-type> <config-file>

OPTIONS:
    -o, --output <dir>      Output directory (default: gitops/<type>)
    -f, --file <name>       Output filename (auto-generated if not specified)
    -v, --validate          Validate generated resources with kubectl
    -d, --dry-run           Print output to stdout instead of file
    -l, --list              List available templates
    -h, --help              Show this help message

TEMPLATE TYPES:
    argocd-app-directory    ArgoCD Application with directory source
    argocd-app-helm         ArgoCD Application with Helm chart source
    argocd-app-multisource  ArgoCD Application with multiple sources
    deployment-service      Deployment + Service
    configmap               ConfigMap
    externalsecret          ExternalSecret
    ingress                 Ingress
    cronjob                 CronJob
    pvc                     PersistentVolumeClaim
    namespace               Namespace
    serviceaccount-rbac     ServiceAccount + ClusterRole + ClusterRoleBinding

CONFIG FILE FORMATS:
    - YAML (.yaml, .yml)
    - JSON (.json)
    - Shell variables (.env, .sh)

EXAMPLES:
    # Generate ArgoCD Application from YAML config
    $(basename "$0") argocd-app-directory my-app.yaml

    # Generate with custom output location
    $(basename "$0") -o gitops/clusters/homelab deployment-service my-app.yaml

    # Dry run to preview output
    $(basename "$0") -d argocd-app-helm my-helm-app.yaml

    # List available templates
    $(basename "$0") -l

EOF
    exit 0
}

# List available templates
list_templates() {
    log_info "Available templates in ${TEMPLATES_DIR}:"
    echo ""
    for template in "$TEMPLATES_DIR"/*.tmpl; do
        if [[ -f "$template" ]]; then
            local name
            name=$(basename "$template" .yaml.tmpl)
            echo -e "  ${GREEN}${name}${NC}"
            # Show first comment line as description
            local desc
            desc=$(grep -m 1 "^# " "$template" | sed 's/^# //')
            if [[ -n "$desc" ]]; then
                echo -e "    ${BLUE}${desc}${NC}"
            fi
            echo ""
        fi
    done
    exit 0
}

# Process template with variable substitution
process_template() {
    local template_file="$1"

    # Use Python template processor if available, otherwise fallback to basic sed
    if command -v python3 &>/dev/null && [[ -f "${SCRIPT_DIR}/template-processor.py" ]]; then
        python3 "${SCRIPT_DIR}/template-processor.py" "$template_file"
    else
        log_warn "Python3 not found, using basic template processing"
        # Fallback: Basic sed-based replacement (no conditionals)
        local output
        output=$(cat "$template_file")

        # Replace {{VAR|default:value}} with default if VAR not set
        while [[ $output =~ \{\{([A-Z_]+)\|default:([^}]+)\}\} ]]; do
            local var_name="${BASH_REMATCH[1]}"
            local default_value="${BASH_REMATCH[2]}"
            local var_value="${!var_name:-$default_value}"
            output="${output//\{\{${var_name}|default:${default_value}\}\}/$var_value}"
        done

        # Replace {{VAR}} with value
        for var in $(env | grep '^[A-Z_]*=' | cut -d= -f1); do
            local value="${!var}"
            output="${output//\{\{${var}\}\}/$value}"
        done

        echo -n "$output"
    fi
}

# Load configuration from file
load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi

    local ext="${config_file##*.}"

    case "$ext" in
        yaml|yml)
            # Parse YAML (simple key: value format)
            while IFS=': ' read -r key value; do
                # Skip comments and empty lines
                [[ $key =~ ^#.*$ ]] || [[ -z $key ]] && continue
                # Remove leading/trailing whitespace and quotes
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
                # Convert key to uppercase and replace - with _
                key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                export "$key=$value"
            done < <(grep -v '^ *#' "$config_file" | grep -v '^---' | grep ': ')
            ;;
        json)
            # Parse JSON
            if command -v jq &>/dev/null; then
                while IFS='=' read -r key value; do
                    export "$key=$value"
                done < <(jq -r 'to_entries | .[] | "\(.key | ascii_upcase)=\(.value)"' "$config_file")
            else
                log_error "jq is required to parse JSON config files"
                exit 1
            fi
            ;;
        env|sh)
            # Source shell variables
            # shellcheck disable=SC1090
            source "$config_file"
            ;;
        *)
            log_error "Unsupported config file format: $ext"
            log_info "Supported formats: yaml, yml, json, env, sh"
            exit 1
            ;;
    esac
}

# Validate Kubernetes resource
validate_resource() {
    local resource_file="$1"

    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found, skipping validation"
        return 0
    fi

    log_info "Validating resource..."
    if kubectl apply --dry-run=client -f "$resource_file" &>/dev/null; then
        log_success "Resource validation passed"
        return 0
    else
        log_error "Resource validation failed"
        kubectl apply --dry-run=client -f "$resource_file" || true
        return 1
    fi
}

# Main function
main() {
    local template_type=""
    local config_file=""
    local output_dir=""
    local output_file=""
    local validate=false
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -l|--list)
                list_templates
                ;;
            -o|--output)
                output_dir="$2"
                shift 2
                ;;
            -f|--file)
                output_file="$2"
                shift 2
                ;;
            -v|--validate)
                validate=true
                shift
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "$template_type" ]]; then
                    template_type="$1"
                elif [[ -z "$config_file" ]]; then
                    config_file="$1"
                else
                    log_error "Too many arguments"
                    usage
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$template_type" ]] || [[ -z "$config_file" ]]; then
        log_error "Missing required arguments"
        usage
    fi

    # Find template file
    local template_file="${TEMPLATES_DIR}/${template_type}.yaml.tmpl"
    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: $template_type"
        log_info "Use -l to list available templates"
        exit 1
    fi

    # Load configuration
    log_info "Loading configuration from: $config_file"
    load_config "$config_file"

    # Process template
    log_info "Processing template: $template_type"
    local output
    output=$(process_template "$template_file")

    # Dry run - print to stdout
    if $dry_run; then
        echo "$output"
        exit 0
    fi

    # Determine output location
    if [[ -z "$output_dir" ]]; then
        # Default output directory based on template type
        case "$template_type" in
            argocd-app-*)
                output_dir="${DEFAULT_OUTPUT_DIR}/clusters/homelab"
                ;;
            *)
                output_dir="${DEFAULT_OUTPUT_DIR}/apps"
                ;;
        esac
    fi

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    # Determine output filename
    if [[ -z "$output_file" ]]; then
        local app_name="${APP_NAME:-${CONFIGMAP_NAME:-${SECRET_NAME:-${CRONJOB_NAME:-${PVC_NAME:-resource}}}}}"
        output_file="${app_name}.yaml"
    fi

    local output_path="${output_dir}/${output_file}"

    # Write output
    echo "$output" > "$output_path"
    log_success "Generated resource: $output_path"

    # Validate if requested
    if $validate; then
        validate_resource "$output_path"
    fi

    # Show next steps
    echo ""
    log_info "Next steps:"
    echo "  1. Review the generated file: $output_path"
    echo "  2. Validate with kubectl: kubectl apply --dry-run=client -f $output_path"
    echo "  3. Commit to git: git add $output_path && git commit -m 'Add ${app_name}'"
    echo "  4. Push to trigger ArgoCD sync: git push"
}

# Run main function
main "$@"
