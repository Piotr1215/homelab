#!/usr/bin/env bash
# Kubernetes Certificate Management Script
# Based on official Kubernetes documentation:
# https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
CERT_DIR="${CERT_DIR:-/etc/kubernetes/pki}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-maintenance}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/cert-management-${TIMESTAMP}.log"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/k8s-certs}"
ALERT_DAYS="${ALERT_DAYS:-30}"

# Ensure directories exist
mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"

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
Usage: $0 [COMMAND]

Manage Kubernetes certificates for kubeadm-based clusters.

COMMANDS:
    check       Check certificate expiration dates
    renew       Renew all certificates
    backup      Backup current certificates
    restore     Restore certificates from backup
    help        Show this help message

EXAMPLES:
    $0 check           # Check when certificates expire
    $0 renew           # Renew all certificates
    $0 backup          # Create certificate backup

NOTES:
    - Requires kubeadm to be installed
    - Must be run on control plane node
    - Will restart control plane pods automatically
    - Kubeadm-generated certificates expire after 1 year by default
EOF
    exit 0
}

# Check if running on control plane node
check_control_plane() {
    log_info "Verifying control plane node..."

    if [[ ! -f "/etc/kubernetes/admin.conf" ]]; then
        error_exit "Not running on a control plane node (admin.conf not found)"
    fi

    if ! command -v kubeadm &> /dev/null; then
        error_exit "kubeadm not found. This script requires kubeadm."
    fi

    log_success "Running on control plane node"
}

# Check certificate expiration
check_expiration() {
    log_info "Checking certificate expiration dates..."

    if ! kubeadm certs check-expiration 2>&1 | tee -a "${LOG_FILE}"; then
        log_warning "Unable to check certificate expiration"
        return 1
    fi

    echo "" | tee -a "${LOG_FILE}"

    # Parse expiration and warn if certificates expire soon
    local expiring_soon=false
    local output=$(kubeadm certs check-expiration 2>/dev/null)

    # Check for certificates expiring within ALERT_DAYS
    if echo "${output}" | grep -E "[0-9]+d" | awk '{print $5}' | sed 's/d//' | while read days; do
        if [[ ${days} -lt ${ALERT_DAYS} ]]; then
            echo "true"
            break
        fi
    done | grep -q "true"; then
        expiring_soon=true
    fi

    if [[ "${expiring_soon}" == "true" ]]; then
        log_warning "Some certificates expire within ${ALERT_DAYS} days!"
        log_warning "Consider running: $0 renew"
    else
        log_success "All certificates valid for at least ${ALERT_DAYS} days"
    fi
}

# Backup certificates
backup_certificates() {
    log_info "Backing up Kubernetes certificates..."

    local backup_path="${BACKUP_DIR}/k8s-certs-${TIMESTAMP}"
    mkdir -p "${backup_path}"

    # Backup PKI directory
    if [[ -d "${CERT_DIR}" ]]; then
        if cp -r "${CERT_DIR}" "${backup_path}/pki"; then
            log_success "PKI directory backed up"
        else
            error_exit "Failed to backup PKI directory"
        fi
    fi

    # Backup kubeconfig files
    for config in admin.conf controller-manager.conf scheduler.conf kubelet.conf; do
        if [[ -f "/etc/kubernetes/${config}" ]]; then
            cp "/etc/kubernetes/${config}" "${backup_path}/" 2>&1 | tee -a "${LOG_FILE}"
            log_info "Backed up ${config}"
        fi
    done

    # Create backup archive
    local archive="${BACKUP_DIR}/k8s-certs-${TIMESTAMP}.tar.gz"
    if tar -czf "${archive}" -C "${BACKUP_DIR}" "k8s-certs-${TIMESTAMP}"; then
        rm -rf "${backup_path}"
        log_success "Certificate backup created: ${archive}"

        # Set restrictive permissions
        chmod 600 "${archive}"
        log_info "Backup permissions set to 600"
    else
        error_exit "Failed to create backup archive"
    fi

    # Cleanup old backups (keep last 10)
    log_info "Cleaning up old backups (keeping last 10)..."
    ls -t "${BACKUP_DIR}"/k8s-certs-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
}

# Restore certificates
restore_certificates() {
    log_info "Restoring certificates from backup..."

    # List available backups
    echo -e "${YELLOW}Available backups:${NC}"
    ls -lh "${BACKUP_DIR}"/k8s-certs-*.tar.gz 2>/dev/null || {
        error_exit "No backups found in ${BACKUP_DIR}"
    }

    echo ""
    read -p "Enter backup file name (or 'latest' for most recent): " backup_file

    if [[ "${backup_file}" == "latest" ]]; then
        backup_file=$(ls -t "${BACKUP_DIR}"/k8s-certs-*.tar.gz 2>/dev/null | head -1)
    elif [[ ! "${backup_file}" =~ ^/ ]]; then
        backup_file="${BACKUP_DIR}/${backup_file}"
    fi

    if [[ ! -f "${backup_file}" ]]; then
        error_exit "Backup file not found: ${backup_file}"
    fi

    log_warning "This will restore certificates from: ${backup_file}"
    read -p "Are you sure? Type 'yes' to continue: " -r
    if [[ ! $REPLY =~ ^yes$ ]]; then
        log_info "Restore cancelled"
        return 0
    fi

    # Stop control plane
    stop_control_plane

    # Backup current certificates before restore
    backup_certificates

    # Extract and restore
    local restore_dir="/tmp/k8s-cert-restore-${TIMESTAMP}"
    mkdir -p "${restore_dir}"

    if tar -xzf "${backup_file}" -C "${restore_dir}"; then
        # Restore PKI
        if [[ -d "${restore_dir}"/k8s-certs-*/pki ]]; then
            rm -rf "${CERT_DIR}"
            cp -r "${restore_dir}"/k8s-certs-*/pki "${CERT_DIR}"
            log_success "PKI directory restored"
        fi

        # Restore kubeconfig files
        for config in admin.conf controller-manager.conf scheduler.conf kubelet.conf; do
            if [[ -f "${restore_dir}/k8s-certs-*/${config}" ]]; then
                cp "${restore_dir}/k8s-certs-*/${config}" "/etc/kubernetes/"
                log_info "Restored ${config}"
            fi
        done

        rm -rf "${restore_dir}"
        log_success "Certificates restored successfully"
    else
        error_exit "Failed to extract backup archive"
    fi

    # Start control plane
    start_control_plane
}

# Renew certificates
renew_certificates() {
    log_info "Renewing all Kubernetes certificates..."

    # Safety confirmation
    echo -e "${YELLOW}This will renew all kubeadm-managed certificates.${NC}"
    echo -e "${YELLOW}Control plane pods will be restarted automatically.${NC}"
    read -p "Continue? Type 'yes': " -r
    if [[ ! $REPLY =~ ^yes$ ]]; then
        log_info "Certificate renewal cancelled"
        return 0
    fi

    # Backup before renewal
    backup_certificates

    # Renew all certificates
    log_info "Renewing certificates with kubeadm..."
    if kubeadm certs renew all 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "All certificates renewed successfully"
    else
        error_exit "Certificate renewal failed"
    fi

    # Restart control plane pods
    restart_control_plane

    # Verify renewal
    echo ""
    log_info "Certificate status after renewal:"
    kubeadm certs check-expiration 2>&1 | tee -a "${LOG_FILE}"
}

# Stop control plane pods
stop_control_plane() {
    log_info "Stopping control plane pods..."

    local manifest_dir="/etc/kubernetes/manifests"
    local manifest_backup="/tmp/k8s-manifests-backup-${TIMESTAMP}"

    if [[ -d "${manifest_dir}" ]]; then
        mkdir -p "${manifest_backup}"

        for manifest in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml; do
            if [[ -f "${manifest_dir}/${manifest}" ]]; then
                mv "${manifest_dir}/${manifest}" "${manifest_backup}/"
                log_info "Stopped ${manifest}"
            fi
        done

        log_info "Waiting for pods to terminate..."
        sleep 20
        log_success "Control plane pods stopped"
    fi
}

# Start control plane pods
start_control_plane() {
    log_info "Starting control plane pods..."

    local manifest_dir="/etc/kubernetes/manifests"
    local manifest_backup="/tmp/k8s-manifests-backup-${TIMESTAMP}"

    if [[ -d "${manifest_backup}" ]]; then
        for manifest in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml; do
            if [[ -f "${manifest_backup}/${manifest}" ]]; then
                mv "${manifest_backup}/${manifest}" "${manifest_dir}/"
                log_info "Started ${manifest}"
            fi
        done

        log_info "Waiting for pods to start..."
        sleep 30
        log_success "Control plane pods started"
    fi
}

# Restart control plane pods for certificate renewal
restart_control_plane() {
    log_info "Restarting control plane pods..."

    # For certificate renewal, we need to restart pods by temporarily removing manifests
    local manifest_dir="/etc/kubernetes/manifests"

    for manifest in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml; do
        if [[ -f "${manifest_dir}/${manifest}" ]]; then
            log_info "Restarting ${manifest%.yaml}..."

            # Move manifest out temporarily
            mv "${manifest_dir}/${manifest}" /tmp/
            sleep 5

            # Move it back to trigger restart
            mv /tmp/"${manifest}" "${manifest_dir}/"
            log_info "${manifest%.yaml} restarted"
        fi
    done

    log_info "Waiting for control plane to stabilize..."
    sleep 30

    # Verify cluster is accessible
    if kubectl cluster-info &> /dev/null; then
        log_success "Control plane restarted successfully"
    else
        log_warning "Control plane may need more time to start"
    fi
}

# Update kubeconfig files
update_kubeconfig() {
    log_info "Updating kubeconfig files..."

    # Update admin kubeconfig
    if [[ -f "/etc/kubernetes/admin.conf" ]]; then
        if [[ -f "$HOME/.kube/config" ]]; then
            cp "$HOME/.kube/config" "$HOME/.kube/config.backup-${TIMESTAMP}"
        fi

        mkdir -p "$HOME/.kube"
        cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
        chmod 600 "$HOME/.kube/config"
        log_success "Kubeconfig updated"
    fi
}

# Display certificate information
show_cert_info() {
    log_info "Certificate Information:"
    echo ""

    # Show API server certificate details
    if [[ -f "${CERT_DIR}/apiserver.crt" ]]; then
        log_info "API Server Certificate:"
        openssl x509 -in "${CERT_DIR}/apiserver.crt" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After" | tee -a "${LOG_FILE}"
        echo ""
    fi

    # Show CA certificate details
    if [[ -f "${CERT_DIR}/ca.crt" ]]; then
        log_info "CA Certificate:"
        openssl x509 -in "${CERT_DIR}/ca.crt" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After" | tee -a "${LOG_FILE}"
        echo ""
    fi
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     🔐 Kubernetes Certificate Manager 🔐                      ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local command="${1:-check}"

    case "${command}" in
        check)
            check_control_plane
            check_expiration
            show_cert_info
            ;;
        renew)
            check_control_plane
            renew_certificates
            update_kubeconfig
            ;;
        backup)
            check_control_plane
            backup_certificates
            ;;
        restore)
            check_control_plane
            restore_certificates
            update_kubeconfig
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            ;;
    esac

    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Operation completed${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    log_success "Log file: ${LOG_FILE}"
}

# Run main function
main "$@"
