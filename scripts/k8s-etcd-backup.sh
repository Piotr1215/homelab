#!/usr/bin/env bash
# Kubernetes etcd Backup Script
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
RETENTION_DAYS="${RETENTION_DAYS:-30}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-https://127.0.0.1:2379}"
ETCD_CERT_DIR="${ETCD_CERT_DIR:-/etc/kubernetes/pki/etcd}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"
LOG_FILE="${LOG_DIR}/etcd-backup-${TIMESTAMP}.log"
ENCRYPT_BACKUP="${ENCRYPT_BACKUP:-false}"
ENCRYPTION_KEY_FILE="${ENCRYPTION_KEY_FILE:-/etc/kubernetes/backup-encryption-key}"

# Ensure log and backup directories exist
mkdir -p "${BACKUP_DIR}" "${LOG_DIR}"

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

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

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Safety check - verify etcd is accessible
check_etcd_health() {
    log_info "Checking etcd cluster health..."

    if ! command -v etcdctl &> /dev/null; then
        error_exit "etcdctl command not found. Please install etcd-client."
    fi

    local health_output
    if health_output=$(ETCDCTL_API=3 etcdctl \
        --endpoints="${ETCD_ENDPOINTS}" \
        --cacert="${ETCD_CERT_DIR}/ca.crt" \
        --cert="${ETCD_CERT_DIR}/server.crt" \
        --key="${ETCD_CERT_DIR}/server.key" \
        endpoint health 2>&1); then
        log_success "etcd cluster is healthy"
        echo "${health_output}" | tee -a "${LOG_FILE}"
    else
        error_exit "etcd cluster health check failed: ${health_output}"
    fi
}

# Create etcd snapshot
create_snapshot() {
    log_info "Creating etcd snapshot: ${BACKUP_FILE}"

    # Create snapshot using official etcdctl snapshot save command
    if ETCDCTL_API=3 etcdctl \
        --endpoints="${ETCD_ENDPOINTS}" \
        --cacert="${ETCD_CERT_DIR}/ca.crt" \
        --cert="${ETCD_CERT_DIR}/server.crt" \
        --key="${ETCD_CERT_DIR}/server.key" \
        snapshot save "${BACKUP_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Snapshot created successfully"
    else
        error_exit "Failed to create etcd snapshot"
    fi
}

# Verify snapshot integrity
verify_snapshot() {
    log_info "Verifying snapshot integrity..."

    if ! command -v etcdutl &> /dev/null; then
        log_warning "etcdutl not found, skipping integrity verification"
        return 0
    fi

    local verify_output
    if verify_output=$(etcdutl --write-out=table snapshot status "${BACKUP_FILE}" 2>&1); then
        log_success "Snapshot integrity verified"
        echo "${verify_output}" | tee -a "${LOG_FILE}"
    else
        log_warning "Snapshot verification failed: ${verify_output}"
    fi
}

# Encrypt snapshot if enabled
encrypt_snapshot() {
    if [[ "${ENCRYPT_BACKUP}" == "true" ]]; then
        log_info "Encrypting snapshot..."

        if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
            log_warning "Encryption key file not found at ${ENCRYPTION_KEY_FILE}, skipping encryption"
            return 0
        fi

        if command -v openssl &> /dev/null; then
            if openssl enc -aes-256-cbc -salt \
                -in "${BACKUP_FILE}" \
                -out "${BACKUP_FILE}.enc" \
                -pass file:"${ENCRYPTION_KEY_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
                rm -f "${BACKUP_FILE}"
                mv "${BACKUP_FILE}.enc" "${BACKUP_FILE}"
                log_success "Snapshot encrypted successfully"
            else
                log_warning "Failed to encrypt snapshot"
            fi
        else
            log_warning "openssl not found, skipping encryption"
        fi
    fi
}

# Compress snapshot
compress_snapshot() {
    log_info "Compressing snapshot..."

    if command -v gzip &> /dev/null; then
        if gzip -f "${BACKUP_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
            BACKUP_FILE="${BACKUP_FILE}.gz"
            log_success "Snapshot compressed successfully"
        else
            log_warning "Failed to compress snapshot"
        fi
    else
        log_warning "gzip not found, skipping compression"
    fi
}

# Calculate backup size
get_backup_size() {
    local size=$(du -h "${BACKUP_FILE}" | cut -f1)
    log_info "Backup size: ${size}"
}

# Cleanup old backups
cleanup_old_backups() {
    log_info "Cleaning up backups older than ${RETENTION_DAYS} days..."

    local deleted_count=0
    while IFS= read -r old_backup; do
        log_info "Removing old backup: ${old_backup}"
        rm -f "${old_backup}"
        ((deleted_count++))
    done < <(find "${BACKUP_DIR}" -name "etcd-snapshot-*.db*" -type f -mtime +${RETENTION_DAYS})

    if [[ ${deleted_count} -gt 0 ]]; then
        log_success "Removed ${deleted_count} old backup(s)"
    else
        log_info "No old backups to remove"
    fi
}

# Cleanup old logs
cleanup_old_logs() {
    log_info "Cleaning up logs older than ${RETENTION_DAYS} days..."

    find "${LOG_DIR}" -name "etcd-backup-*.log" -type f -mtime +${RETENTION_DAYS} -delete
}

# Verify Kubernetes cluster connectivity
verify_k8s_cluster() {
    log_info "Verifying Kubernetes cluster connectivity..."

    if command -v kubectl &> /dev/null; then
        if kubectl cluster-info &> /dev/null; then
            log_success "Kubernetes cluster is accessible"
        else
            log_warning "Cannot access Kubernetes cluster (kubectl cluster-info failed)"
        fi
    else
        log_warning "kubectl not found, skipping cluster verification"
    fi
}

# Create backup metadata
create_metadata() {
    local metadata_file="${BACKUP_FILE}.metadata"
    log_info "Creating backup metadata: ${metadata_file}"

    cat > "${metadata_file}" <<EOF
# etcd Backup Metadata
backup_timestamp: ${TIMESTAMP}
backup_file: ${BACKUP_FILE}
etcd_endpoints: ${ETCD_ENDPOINTS}
kubernetes_version: $(kubectl version --short 2>/dev/null || echo "N/A")
node_count: $(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "N/A")
namespace_count: $(kubectl get namespaces --no-headers 2>/dev/null | wc -l || echo "N/A")
retention_days: ${RETENTION_DAYS}
encrypted: ${ENCRYPT_BACKUP}
EOF

    log_success "Metadata file created"
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🔒 Kubernetes etcd Backup Script 🔒                        ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_info "Starting etcd backup process..."
    log_info "Backup directory: ${BACKUP_DIR}"
    log_info "Retention period: ${RETENTION_DAYS} days"

    # Execute backup workflow
    verify_k8s_cluster
    check_etcd_health
    create_snapshot
    verify_snapshot
    encrypt_snapshot
    compress_snapshot
    get_backup_size
    create_metadata
    cleanup_old_backups
    cleanup_old_logs

    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Backup completed successfully!${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    log_success "Backup file: ${BACKUP_FILE}"
    log_success "Log file: ${LOG_FILE}"
    echo ""

    # List recent backups
    log_info "Recent backups:"
    ls -lh "${BACKUP_DIR}"/etcd-snapshot-*.db* 2>/dev/null | tail -5 | tee -a "${LOG_FILE}" || log_info "No backups found"
}

# Run main function
main "$@"
