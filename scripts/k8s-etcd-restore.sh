#!/usr/bin/env bash
# Kubernetes etcd Restore Script
# Based on official Kubernetes documentation:
# https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/etcd}"
ETCD_DATA_DIR="${ETCD_DATA_DIR:-/var/lib/etcd}"
ETCD_CERT_DIR="${ETCD_CERT_DIR:-/etc/kubernetes/pki/etcd}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/etcd-restore-${TIMESTAMP}.log"
RESTORE_DATA_DIR="${ETCD_DATA_DIR}-restore-${TIMESTAMP}"
DECRYPT_BACKUP="${DECRYPT_BACKUP:-false}"
ENCRYPTION_KEY_FILE="${ENCRYPTION_KEY_FILE:-/etc/kubernetes/backup-encryption-key}"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

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

error_exit() {
    log_error "$1"
    exit 1
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <snapshot-file>

Restore etcd from a backup snapshot.

OPTIONS:
    -h, --help              Show this help message
    -n, --name              etcd cluster name (default: default)
    -d, --data-dir          Target data directory for restore
    -i, --initial-cluster   Initial cluster configuration
    -a, --initial-advertise-peer-urls  Initial advertise peer URLs

EXAMPLE:
    $0 /var/backups/etcd/etcd-snapshot-20231208-120000.db.gz
    $0 -d /var/lib/etcd-new /var/backups/etcd/latest-snapshot.db

NOTES:
    - This is a DESTRUCTIVE operation
    - etcd cluster must be stopped before restore
    - All control plane components will be affected
    - Ensure you have verified the backup integrity before proceeding
EOF
    exit 1
}

# Safety confirmation
confirm_restore() {
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                    ⚠️  WARNING  ⚠️                             ${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}This will restore etcd from a backup snapshot.${NC}"
    echo -e "${YELLOW}This is a DESTRUCTIVE operation that will:${NC}"
    echo -e "${YELLOW}  - Stop the etcd cluster${NC}"
    echo -e "${YELLOW}  - Replace current cluster data${NC}"
    echo -e "${YELLOW}  - Affect all Kubernetes control plane operations${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Snapshot to restore: ${BLUE}${SNAPSHOT_FILE}${NC}"
    echo -e "Current etcd data: ${BLUE}${ETCD_DATA_DIR}${NC}"
    echo -e "Restore target: ${BLUE}${RESTORE_DATA_DIR}${NC}"
    echo ""

    read -p "Are you sure you want to proceed? Type 'yes' to continue: " -r
    echo
    if [[ ! $REPLY =~ ^yes$ ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi

    log_warning "User confirmed restore operation"
}

# Pre-flight checks
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi

    # Check if etcdutl is available
    if ! command -v etcdutl &> /dev/null; then
        error_exit "etcdutl command not found. Please install etcd-client."
    fi

    # Check if snapshot file exists
    if [[ ! -f "${SNAPSHOT_FILE}" ]]; then
        error_exit "Snapshot file not found: ${SNAPSHOT_FILE}"
    fi

    log_success "Pre-flight checks passed"
}

# Decompress snapshot if needed
decompress_snapshot() {
    if [[ "${SNAPSHOT_FILE}" == *.gz ]]; then
        log_info "Decompressing snapshot..."
        local decompressed="${SNAPSHOT_FILE%.gz}"

        if gunzip -c "${SNAPSHOT_FILE}" > "${decompressed}"; then
            SNAPSHOT_FILE="${decompressed}"
            log_success "Snapshot decompressed: ${SNAPSHOT_FILE}"
        else
            error_exit "Failed to decompress snapshot"
        fi
    fi
}

# Decrypt snapshot if needed
decrypt_snapshot() {
    if [[ "${DECRYPT_BACKUP}" == "true" ]]; then
        log_info "Decrypting snapshot..."

        if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
            error_exit "Encryption key file not found: ${ENCRYPTION_KEY_FILE}"
        fi

        local decrypted="${SNAPSHOT_FILE%.enc}"
        if openssl enc -aes-256-cbc -d \
            -in "${SNAPSHOT_FILE}" \
            -out "${decrypted}" \
            -pass file:"${ENCRYPTION_KEY_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
            SNAPSHOT_FILE="${decrypted}"
            log_success "Snapshot decrypted successfully"
        else
            error_exit "Failed to decrypt snapshot"
        fi
    fi
}

# Verify snapshot integrity
verify_snapshot() {
    log_info "Verifying snapshot integrity..."

    if etcdutl --write-out=table snapshot status "${SNAPSHOT_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Snapshot integrity verified"
    else
        error_exit "Snapshot integrity check failed"
    fi
}

# Backup current etcd data
backup_current_data() {
    log_info "Backing up current etcd data..."

    if [[ -d "${ETCD_DATA_DIR}" ]]; then
        local backup_current="${ETCD_DATA_DIR}.backup-${TIMESTAMP}"
        if mv "${ETCD_DATA_DIR}" "${backup_current}"; then
            log_success "Current data backed up to: ${backup_current}"
        else
            error_exit "Failed to backup current etcd data"
        fi
    else
        log_warning "No existing etcd data directory found"
    fi
}

# Stop etcd and control plane components
stop_etcd() {
    log_info "Stopping etcd and control plane components..."

    # Move static pod manifests temporarily to stop them
    local manifest_dir="/etc/kubernetes/manifests"
    local manifest_backup="/tmp/k8s-manifests-${TIMESTAMP}"

    if [[ -d "${manifest_dir}" ]]; then
        mkdir -p "${manifest_backup}"
        log_info "Moving control plane manifests to: ${manifest_backup}"

        for manifest in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
            if [[ -f "${manifest_dir}/${manifest}" ]]; then
                mv "${manifest_dir}/${manifest}" "${manifest_backup}/" 2>&1 | tee -a "${LOG_FILE}"
                log_info "Moved ${manifest}"
            fi
        done

        log_info "Waiting for etcd to stop..."
        sleep 20
        log_success "Control plane components stopped"
    else
        log_warning "Manifests directory not found, etcd may need to be stopped manually"
    fi
}

# Restore etcd from snapshot
restore_etcd() {
    log_info "Restoring etcd from snapshot..."

    # Perform the restore using etcdutl
    if etcdutl snapshot restore "${SNAPSHOT_FILE}" \
        --name="${CLUSTER_NAME}" \
        --initial-cluster="${INITIAL_CLUSTER}" \
        --initial-advertise-peer-urls="${INITIAL_ADVERTISE_PEER_URLS}" \
        --data-dir="${RESTORE_DATA_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "etcd restored to: ${RESTORE_DATA_DIR}"
    else
        error_exit "Failed to restore etcd from snapshot"
    fi

    # Move restored data to final location
    if mv "${RESTORE_DATA_DIR}" "${ETCD_DATA_DIR}"; then
        log_success "Restored data moved to: ${ETCD_DATA_DIR}"
    else
        error_exit "Failed to move restored data to final location"
    fi

    # Set correct permissions
    chown -R root:root "${ETCD_DATA_DIR}"
    log_success "Permissions set on restored data"
}

# Start etcd and control plane components
start_etcd() {
    log_info "Starting etcd and control plane components..."

    local manifest_dir="/etc/kubernetes/manifests"
    local manifest_backup="/tmp/k8s-manifests-${TIMESTAMP}"

    if [[ -d "${manifest_backup}" ]]; then
        for manifest in etcd.yaml kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml; do
            if [[ -f "${manifest_backup}/${manifest}" ]]; then
                mv "${manifest_backup}/${manifest}" "${manifest_dir}/" 2>&1 | tee -a "${LOG_FILE}"
                log_info "Restored ${manifest}"
            fi
        done

        log_info "Waiting for control plane to start..."
        sleep 30
        log_success "Control plane components started"
    fi
}

# Verify cluster health
verify_cluster() {
    log_info "Verifying cluster health..."

    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if kubectl cluster-info &> /dev/null; then
            log_success "Kubernetes cluster is accessible"

            # Display cluster info
            kubectl get nodes 2>&1 | tee -a "${LOG_FILE}"
            kubectl get pods --all-namespaces 2>&1 | tee -a "${LOG_FILE}"
            return 0
        fi

        log_info "Waiting for cluster to become ready (attempt ${attempt}/${max_attempts})..."
        sleep 10
        ((attempt++))
    done

    log_warning "Cluster health verification timed out. Manual verification may be needed."
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🔄 Kubernetes etcd Restore Script 🔄                       ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Parse arguments
    CLUSTER_NAME="${CLUSTER_NAME:-default}"
    INITIAL_CLUSTER="${INITIAL_CLUSTER:-default=https://127.0.0.1:2380}"
    INITIAL_ADVERTISE_PEER_URLS="${INITIAL_ADVERTISE_PEER_URLS:-https://127.0.0.1:2380}"

    if [[ $# -eq 0 ]]; then
        usage
    fi

    # Get snapshot file from last argument
    SNAPSHOT_FILE="${!#}"

    log_info "Starting etcd restore process..."
    log_info "Snapshot file: ${SNAPSHOT_FILE}"

    # Execute restore workflow
    preflight_checks
    confirm_restore
    decompress_snapshot
    decrypt_snapshot
    verify_snapshot
    stop_etcd
    backup_current_data
    restore_etcd
    start_etcd
    verify_cluster

    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Restore completed successfully!${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    log_success "Restore log: ${LOG_FILE}"
    echo ""
    log_info "Please verify your cluster state and applications"
}

# Run main function
main "$@"
