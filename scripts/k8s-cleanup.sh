#!/usr/bin/env bash
# Kubernetes Resource Cleanup and Garbage Collection Script
# Based on official Kubernetes documentation:
# https://kubernetes.io/docs/concepts/architecture/garbage-collection/
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
LOG_FILE="${LOG_DIR}/cleanup-${TIMESTAMP}.log"
DRY_RUN="${DRY_RUN:-true}"
COMPLETED_JOB_TTL="${COMPLETED_JOB_TTL:-24h}"
FAILED_POD_AGE="${FAILED_POD_AGE:-7d}"
EVICTED_POD_CLEANUP="${EVICTED_POD_CLEANUP:-true}"
UNUSED_PV_CLEANUP="${UNUSED_PV_CLEANUP:-false}"
UNUSED_CONFIGMAP_CLEANUP="${UNUSED_CONFIGMAP_CLEANUP:-false}"
UNUSED_SECRET_CLEANUP="${UNUSED_SECRET_CLEANUP:-false}"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Cleanup statistics
RESOURCES_FOUND=0
RESOURCES_CLEANED=0

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

log_cleanup() {
    echo -e "${CYAN}[CLEANUP]${NC} $*" | tee -a "${LOG_FILE}"
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Clean up unused and orphaned Kubernetes resources.

OPTIONS:
    --execute               Execute cleanup (default is dry-run)
    --completed-jobs        Clean up completed jobs
    --failed-pods           Clean up failed pods
    --evicted-pods          Clean up evicted pods
    --unused-pvs            Clean up Released PersistentVolumes
    --unused-configmaps     Clean up unused ConfigMaps
    --unused-secrets        Clean up unused Secrets
    --all                   Clean up all resource types
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    DRY_RUN=false              Execute cleanup instead of dry-run
    COMPLETED_JOB_TTL=24h      Age threshold for completed jobs
    FAILED_POD_AGE=7d          Age threshold for failed pods
    EVICTED_POD_CLEANUP=true   Enable evicted pod cleanup
    UNUSED_PV_CLEANUP=false    Enable unused PV cleanup
    UNUSED_CONFIGMAP_CLEANUP=false Enable unused ConfigMap cleanup
    UNUSED_SECRET_CLEANUP=false    Enable unused Secret cleanup

EXAMPLES:
    $0                          # Dry-run of all cleanups
    $0 --execute --failed-pods  # Clean up failed pods
    DRY_RUN=false $0 --all      # Execute all cleanups

NOTES:
    - Default mode is DRY-RUN (shows what would be deleted)
    - Use --execute or DRY_RUN=false to actually delete resources
    - Kubernetes garbage collection handles most cleanup automatically
    - This script targets edge cases and manual cleanup needs
EOF
    exit 0
}

# Convert time string to seconds
time_to_seconds() {
    local time_str=$1
    local value=${time_str%[a-z]}
    local unit=${time_str#${value}}

    case "${unit}" in
        s) echo $((value)) ;;
        m) echo $((value * 60)) ;;
        h) echo $((value * 3600)) ;;
        d) echo $((value * 86400)) ;;
        *) echo 0 ;;
    esac
}

# Get resource age in seconds
get_resource_age() {
    local creation_timestamp=$1
    local current_time=$(date +%s)
    local resource_time=$(date -d "${creation_timestamp}" +%s 2>/dev/null || echo 0)
    echo $((current_time - resource_time))
}

# Delete resource with safety checks
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-}

    ((RESOURCES_FOUND++))

    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ -n "${namespace}" ]]; then
            log_cleanup "[DRY-RUN] Would delete ${resource_type}/${resource_name} in namespace ${namespace}"
        else
            log_cleanup "[DRY-RUN] Would delete ${resource_type}/${resource_name}"
        fi
    else
        log_cleanup "Deleting ${resource_type}/${resource_name}..."

        if [[ -n "${namespace}" ]]; then
            if kubectl delete "${resource_type}" "${resource_name}" -n "${namespace}" --wait=false 2>&1 | tee -a "${LOG_FILE}"; then
                ((RESOURCES_CLEANED++))
                log_success "Deleted ${resource_type}/${resource_name}"
            else
                log_error "Failed to delete ${resource_type}/${resource_name}"
            fi
        else
            if kubectl delete "${resource_type}" "${resource_name}" --wait=false 2>&1 | tee -a "${LOG_FILE}"; then
                ((RESOURCES_CLEANED++))
                log_success "Deleted ${resource_type}/${resource_name}"
            else
                log_error "Failed to delete ${resource_type}/${resource_name}"
            fi
        fi
    fi
}

# Clean up completed jobs
cleanup_completed_jobs() {
    log_info "Checking for completed jobs older than ${COMPLETED_JOB_TTL}..."

    local ttl_seconds=$(time_to_seconds "${COMPLETED_JOB_TTL}")
    local jobs_json=$(kubectl get jobs --all-namespaces -o json 2>/dev/null)

    # Find completed jobs older than TTL
    local old_jobs=$(echo "${jobs_json}" | jq -r --arg ttl "${ttl_seconds}" '
        .items[] |
        select(.status.succeeded == 1) |
        select((now - (.status.completionTime | fromdateiso8601)) > ($ttl | tonumber)) |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${old_jobs}" ]]; then
        log_info "Found completed jobs to clean up:"
        echo "${old_jobs}" | tee -a "${LOG_FILE}"

        echo "${old_jobs}" | while IFS='/' read -r ns job; do
            delete_resource "job" "${job}" "${ns}"
        done
    else
        log_success "No old completed jobs found"
    fi
}

# Clean up failed pods
cleanup_failed_pods() {
    log_info "Checking for failed pods older than ${FAILED_POD_AGE}..."

    local age_seconds=$(time_to_seconds "${FAILED_POD_AGE}")
    local pods_json=$(kubectl get pods --all-namespaces -o json 2>/dev/null)

    # Find failed pods older than threshold
    local failed_pods=$(echo "${pods_json}" | jq -r --arg age "${age_seconds}" '
        .items[] |
        select(.status.phase == "Failed") |
        select((now - (.metadata.creationTimestamp | fromdateiso8601)) > ($age | tonumber)) |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${failed_pods}" ]]; then
        log_info "Found failed pods to clean up:"
        echo "${failed_pods}" | tee -a "${LOG_FILE}"

        echo "${failed_pods}" | while IFS='/' read -r ns pod; do
            delete_resource "pod" "${pod}" "${ns}"
        done
    else
        log_success "No old failed pods found"
    fi
}

# Clean up evicted pods
cleanup_evicted_pods() {
    if [[ "${EVICTED_POD_CLEANUP}" != "true" ]]; then
        return 0
    fi

    log_info "Checking for evicted pods..."

    local evicted_pods=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.reason == "Evicted") |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${evicted_pods}" ]]; then
        log_info "Found evicted pods to clean up:"
        echo "${evicted_pods}" | tee -a "${LOG_FILE}"

        echo "${evicted_pods}" | while IFS='/' read -r ns pod; do
            delete_resource "pod" "${pod}" "${ns}"
        done
    else
        log_success "No evicted pods found"
    fi
}

# Clean up terminated pods
cleanup_terminated_pods() {
    log_info "Checking for terminated pods..."

    local terminated_pods=$(kubectl get pods --all-namespaces \
        --field-selector=status.phase=Succeeded -o json 2>/dev/null | jq -r '
        .items[] |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${terminated_pods}" ]]; then
        log_info "Found terminated pods to clean up:"
        echo "${terminated_pods}" | tee -a "${LOG_FILE}"

        echo "${terminated_pods}" | while IFS='/' read -r ns pod; do
            delete_resource "pod" "${pod}" "${ns}"
        done
    else
        log_success "No terminated pods found"
    fi
}

# Clean up unused PersistentVolumes
cleanup_unused_pvs() {
    if [[ "${UNUSED_PV_CLEANUP}" != "true" ]]; then
        return 0
    fi

    log_info "Checking for Released PersistentVolumes..."

    local released_pvs=$(kubectl get pv -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.phase == "Released") |
        .metadata.name')

    if [[ -n "${released_pvs}" ]]; then
        log_warning "Found Released PVs (may contain data):"
        echo "${released_pvs}" | tee -a "${LOG_FILE}"

        if [[ "${DRY_RUN}" != "true" ]]; then
            echo -e "${RED}WARNING: Deleting PVs will remove data permanently!${NC}"
            read -p "Are you sure? Type 'yes' to continue: " -r
            if [[ ! $REPLY =~ ^yes$ ]]; then
                log_info "PV cleanup cancelled"
                return 0
            fi
        fi

        echo "${released_pvs}" | while read -r pv; do
            delete_resource "pv" "${pv}"
        done
    else
        log_success "No Released PVs found"
    fi
}

# Clean up unused ConfigMaps
cleanup_unused_configmaps() {
    if [[ "${UNUSED_CONFIGMAP_CLEANUP}" != "true" ]]; then
        return 0
    fi

    log_info "Checking for unused ConfigMaps..."

    # Get all ConfigMaps
    local all_cms=$(kubectl get configmaps --all-namespaces -o json 2>/dev/null)

    # Get ConfigMaps referenced by pods
    local used_cms=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[].spec |
        (.volumes[]?.configMap.name, .containers[].envFrom[]?.configMapRef.name) |
        select(. != null)')

    # Find unused ConfigMaps (excluding kube-system and other system namespaces)
    local unused_cms=$(echo "${all_cms}" | jq -r --arg used "${used_cms}" '
        .items[] |
        select(.metadata.namespace != "kube-system") |
        select(.metadata.namespace != "kube-public") |
        select(.metadata.namespace != "kube-node-lease") |
        select((.metadata.name | IN($used)) | not) |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${unused_cms}" ]]; then
        log_info "Found potentially unused ConfigMaps:"
        echo "${unused_cms}" | tee -a "${LOG_FILE}"

        echo "${unused_cms}" | while IFS='/' read -r ns cm; do
            delete_resource "configmap" "${cm}" "${ns}"
        done
    else
        log_success "No unused ConfigMaps found"
    fi
}

# Clean up unused Secrets
cleanup_unused_secrets() {
    if [[ "${UNUSED_SECRET_CLEANUP}" != "true" ]]; then
        return 0
    fi

    log_info "Checking for unused Secrets (excluding service account tokens)..."

    # Get all non-token Secrets
    local all_secrets=$(kubectl get secrets --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.type != "kubernetes.io/service-account-token") |
        .metadata.namespace + "/" + .metadata.name')

    # Get Secrets referenced by pods
    local used_secrets=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[].spec |
        (.volumes[]?.secret.secretName, .containers[].envFrom[]?.secretRef.name) |
        select(. != null)')

    # This is a complex check - in practice, be very careful with secret cleanup
    log_warning "Unused secret detection is complex and potentially dangerous"
    log_warning "Manual verification recommended before cleanup"
}

# Clean up failed StatefulSet pods
cleanup_statefulset_orphans() {
    log_info "Checking for orphaned StatefulSet pods..."

    local orphaned=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.ownerReferences[]?.kind == "StatefulSet") |
        select(.status.phase == "Failed" or .status.phase == "Unknown") |
        .metadata.namespace + "/" + .metadata.name')

    if [[ -n "${orphaned}" ]]; then
        log_info "Found orphaned StatefulSet pods:"
        echo "${orphaned}" | tee -a "${LOG_FILE}"

        echo "${orphaned}" | while IFS='/' read -r ns pod; do
            delete_resource "pod" "${pod}" "${ns}"
        done
    else
        log_success "No orphaned StatefulSet pods found"
    fi
}

# Display current resource usage
show_resource_summary() {
    log_info "Current cluster resource summary:"
    echo ""

    log_info "Pods:"
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
        awk '{print $4}' | sort | uniq -c | tee -a "${LOG_FILE}"
    echo ""

    log_info "Jobs:"
    kubectl get jobs --all-namespaces --no-headers 2>/dev/null | wc -l | \
        xargs -I {} echo "Total jobs: {}" | tee -a "${LOG_FILE}"
    echo ""

    log_info "PersistentVolumes:"
    kubectl get pv --no-headers 2>/dev/null | awk '{print $5}' | sort | uniq -c | tee -a "${LOG_FILE}"
    echo ""
}

# Generate cleanup report
generate_report() {
    echo ""
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Cleanup Summary:"
    log_info "Resources found for cleanup: ${RESOURCES_FOUND}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "DRY-RUN MODE: No resources were actually deleted"
        log_info "Run with --execute or DRY_RUN=false to perform cleanup"
    else
        log_success "Resources cleaned up: ${RESOURCES_CLEANED}"
    fi

    log_info "Log file: ${LOG_FILE}"
    log_info "═══════════════════════════════════════════════════════════════"
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🧹 Kubernetes Resource Cleanup Tool 🧹                    ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "Running in DRY-RUN mode (no resources will be deleted)"
    else
        log_warning "Running in EXECUTE mode (resources will be deleted)"
    fi
    echo ""

    # Show current resource status
    show_resource_summary

    # Parse command line arguments
    local cleanup_jobs=false
    local cleanup_pods=false
    local cleanup_all=false

    if [[ $# -eq 0 ]]; then
        cleanup_all=true
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --execute)
                DRY_RUN=false
                shift
                ;;
            --completed-jobs)
                cleanup_jobs=true
                shift
                ;;
            --failed-pods)
                cleanup_pods=true
                shift
                ;;
            --evicted-pods)
                EVICTED_POD_CLEANUP=true
                shift
                ;;
            --unused-pvs)
                UNUSED_PV_CLEANUP=true
                shift
                ;;
            --unused-configmaps)
                UNUSED_CONFIGMAP_CLEANUP=true
                shift
                ;;
            --unused-secrets)
                UNUSED_SECRET_CLEANUP=true
                shift
                ;;
            --all)
                cleanup_all=true
                shift
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

    # Execute cleanups
    if [[ "${cleanup_all}" == "true" || "${cleanup_jobs}" == "true" ]]; then
        cleanup_completed_jobs
        echo ""
    fi

    if [[ "${cleanup_all}" == "true" || "${cleanup_pods}" == "true" ]]; then
        cleanup_failed_pods
        echo ""
    fi

    if [[ "${cleanup_all}" == "true" ]]; then
        cleanup_evicted_pods
        echo ""

        cleanup_terminated_pods
        echo ""

        cleanup_statefulset_orphans
        echo ""
    fi

    cleanup_unused_pvs
    echo ""

    cleanup_unused_configmaps
    echo ""

    cleanup_unused_secrets
    echo ""

    # Generate final report
    generate_report
}

# Run main function
main "$@"
