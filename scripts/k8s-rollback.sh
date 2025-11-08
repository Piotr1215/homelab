#!/bin/bash
#####################################################################
# Kubernetes Rollback Script
#
# This script provides rollback procedures for failed Kubernetes
# upgrades. Use with extreme caution!
#
# Features:
# - etcd snapshot restoration
# - Package downgrade procedures
# - Backup verification before rollback
# - Component-specific rollback options
# - Safety checks and confirmations
#
# Usage:
#   ./k8s-rollback.sh --help
#   ./k8s-rollback.sh --check-backups
#   ./k8s-rollback.sh --restore-etcd <snapshot-file>
#   ./k8s-rollback.sh --downgrade-packages <version>
#
# IMPORTANT: This should be a last resort. Review all options first!
#####################################################################

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/kubernetes}"
ETCD_BACKUP_DIR="${ETCD_BACKUP_DIR:-${BACKUP_DIR}/etcd}"
LOG_FILE="${LOG_FILE:-/tmp/k8s-rollback-$(date +%Y%m%d-%H%M%S).log}"
DRY_RUN="${DRY_RUN:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${MAGENTA}===================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}===================================================${NC}\n" | tee -a "$LOG_FILE"
}

# Warning banner
show_warning_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║                     ⚠️  DANGER ZONE ⚠️                         ║
║                                                                 ║
║  You are about to perform a Kubernetes cluster ROLLBACK!      ║
║                                                                 ║
║  This operation is EXTREMELY RISKY and should only be          ║
║  performed as a LAST RESORT when:                              ║
║                                                                 ║
║  1. The upgrade has catastrophically failed                    ║
║  2. The cluster is completely non-functional                   ║
║  3. You have verified backups                                  ║
║  4. You have no other recovery options                         ║
║                                                                 ║
║  Rollback can result in:                                       ║
║  - Data loss                                                   ║
║  - Service disruption                                          ║
║  - Cluster corruption                                          ║
║  - Extended downtime                                           ║
║                                                                 ║
║  Consider these alternatives FIRST:                            ║
║  - Wait for pods to stabilize                                  ║
║  - Check for misconfiguration                                  ║
║  - Review logs for specific errors                             ║
║  - Consult Kubernetes documentation                            ║
║  - Seek expert assistance                                      ║
║                                                                 ║
╚═══════════════════════════════════════════════════════════════╝
EOF
}

# Confirmation with typing check
confirm_dangerous_operation() {
    local operation="$1"
    local confirmation_text="YES I UNDERSTAND THE RISKS"

    log_warning "You are about to: $operation"
    echo ""
    echo -e "${RED}To proceed, type exactly: ${YELLOW}$confirmation_text${NC}"
    read -p "> " user_input

    if [ "$user_input" = "$confirmation_text" ]; then
        log_warning "User confirmed dangerous operation"
        return 0
    else
        log_info "Operation cancelled - confirmation failed"
        return 1
    fi
}

# Usage information
show_usage() {
    cat <<EOF
Kubernetes Rollback Script

Usage: $0 [OPTIONS]

OPTIONS:
    --help                          Show this help message
    --check-backups                 Verify available backups
    --list-etcd-snapshots          List available etcd snapshots
    --restore-etcd <snapshot>      Restore etcd from snapshot
    --downgrade-packages <version> Downgrade K8s packages to version
    --restore-resources <backup>   Restore cluster resources from backup
    --dry-run                      Show what would be done without executing

EXAMPLES:
    # Check available backups
    $0 --check-backups

    # List etcd snapshots
    $0 --list-etcd-snapshots

    # Restore etcd from snapshot
    $0 --restore-etcd /var/backups/kubernetes/etcd/etcd-snapshot-20250108-120000.db

    # Downgrade packages to previous version
    $0 --downgrade-packages v1.32.0

IMPORTANT NOTES:
    - Always verify backups before attempting rollback
    - Rollback should be a LAST RESORT
    - Test in non-production first if possible
    - Consult documentation and support before proceeding
    - etcd restore requires stopping the API server

SAFER ALTERNATIVES:
    1. Wait for the upgrade to complete (can take 10+ minutes)
    2. Fix specific failing components
    3. Roll back application deployments instead
    4. Consult upgrade logs for specific errors

For more information:
    https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
EOF
}

# Check if running on control plane
check_control_plane() {
    local hostname=$(hostname)

    if ! kubectl get node "$hostname" -o jsonpath='{.metadata.labels}' | grep -q "node-role.kubernetes.io/control-plane"; then
        log_error "This script must be run on a control plane node"
        log_error "Current node: $hostname"
        exit 1
    fi

    log_info "Running on control plane node: $hostname"
}

# List available backups
check_backups() {
    log_section "Checking Available Backups"

    # Check backup directory
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        return 1
    fi

    log_info "Backup directory: $BACKUP_DIR"

    # Check etcd snapshots
    log_info "\netcd Snapshots:"
    if [ -d "$ETCD_BACKUP_DIR" ] && [ "$(ls -A $ETCD_BACKUP_DIR 2>/dev/null)" ]; then
        ls -lh "$ETCD_BACKUP_DIR" | tee -a "$LOG_FILE"

        # Verify each snapshot
        for snapshot in "$ETCD_BACKUP_DIR"/*.db; do
            if [ -f "$snapshot" ]; then
                log_info "Verifying: $snapshot"
                if command -v etcdctl &> /dev/null; then
                    if ETCDCTL_API=3 etcdctl snapshot status "$snapshot" -w table 2>&1 | tee -a "$LOG_FILE"; then
                        log_success "Snapshot valid: $snapshot"
                    else
                        log_error "Snapshot corrupted: $snapshot"
                    fi
                else
                    log_warning "etcdctl not available - cannot verify snapshots"
                    break
                fi
            fi
        done
    else
        log_warning "No etcd snapshots found in $ETCD_BACKUP_DIR"
    fi

    # Check resource backups
    log_info "\nResource Backups:"
    if ls "$BACKUP_DIR"/resources-* &> /dev/null; then
        ls -lhd "$BACKUP_DIR"/resources-* | tee -a "$LOG_FILE"
    else
        log_warning "No resource backups found"
    fi

    # Check version files
    log_info "\nVersion Information:"
    if [ -f "$BACKUP_DIR/pre-upgrade-version.txt" ]; then
        log_info "Pre-upgrade version:"
        cat "$BACKUP_DIR/pre-upgrade-version.txt" | tee -a "$LOG_FILE"
    fi

    if [ -f "$BACKUP_DIR/pre-upgrade-versions.txt" ]; then
        log_info "Pre-upgrade component versions:"
        cat "$BACKUP_DIR/pre-upgrade-versions.txt" | tee -a "$LOG_FILE"
    fi
}

# List etcd snapshots
list_etcd_snapshots() {
    log_section "Available etcd Snapshots"

    if [ ! -d "$ETCD_BACKUP_DIR" ]; then
        log_error "etcd backup directory not found: $ETCD_BACKUP_DIR"
        return 1
    fi

    local snapshot_count=0
    for snapshot in "$ETCD_BACKUP_DIR"/*.db; do
        if [ -f "$snapshot" ]; then
            ((snapshot_count++))
            local size=$(du -h "$snapshot" | cut -f1)
            local date=$(stat -c %y "$snapshot" | cut -d' ' -f1,2)
            echo "[$snapshot_count] $snapshot"
            echo "    Size: $size"
            echo "    Date: $date"

            if command -v etcdctl &> /dev/null; then
                ETCDCTL_API=3 etcdctl snapshot status "$snapshot" -w table 2>/dev/null || echo "    Status: Cannot verify"
            fi
            echo ""
        fi
    done

    if [ "$snapshot_count" -eq 0 ]; then
        log_warning "No etcd snapshots found"
        return 1
    fi

    log_info "Total snapshots: $snapshot_count"
}

# Restore etcd from snapshot
restore_etcd_snapshot() {
    local snapshot_file="$1"

    log_section "Restoring etcd from Snapshot"

    # Validation checks
    if [ ! -f "$snapshot_file" ]; then
        log_error "Snapshot file not found: $snapshot_file"
        exit 1
    fi

    log_info "Snapshot file: $snapshot_file"
    log_info "Size: $(du -h "$snapshot_file" | cut -f1)"

    # Verify snapshot
    if ! command -v etcdctl &> /dev/null; then
        log_error "etcdctl not found. Cannot restore etcd."
        exit 1
    fi

    log_info "Verifying snapshot integrity..."
    if ! ETCDCTL_API=3 etcdctl snapshot status "$snapshot_file" -w table; then
        log_error "Snapshot verification failed!"
        exit 1
    fi
    log_success "Snapshot is valid"

    # Show current cluster state
    log_info "Current cluster state:"
    kubectl get nodes 2>/dev/null || log_warning "Cannot query cluster (may be expected if API server is down)"

    # Final confirmation
    show_warning_banner
    echo ""
    if ! confirm_dangerous_operation "RESTORE ETCD FROM SNAPSHOT"; then
        log_info "Rollback cancelled"
        exit 0
    fi

    # Stop kube-apiserver
    log_warning "Stopping kube-apiserver..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would stop kube-apiserver"
    else
        # For static pods, move the manifest
        if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
            sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.backup
            log_info "Waiting for kube-apiserver to stop..."
            sleep 20
        else
            log_error "kube-apiserver manifest not found"
            exit 1
        fi
    fi

    # Stop etcd
    log_warning "Stopping etcd..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would stop etcd"
    else
        if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
            sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup
            log_info "Waiting for etcd to stop..."
            sleep 20
        else
            log_error "etcd manifest not found"
            exit 1
        fi
    fi

    # Backup current etcd data
    log_info "Backing up current etcd data..."
    local current_backup="/var/lib/etcd-backup-$(date +%Y%m%d-%H%M%S)"
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would backup to: $current_backup"
    else
        if [ -d /var/lib/etcd ]; then
            sudo cp -r /var/lib/etcd "$current_backup"
            log_success "Current data backed up to: $current_backup"
        fi
    fi

    # Restore from snapshot
    log_info "Restoring etcd from snapshot..."
    local restore_dir="/var/lib/etcd-restored"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restore snapshot to: $restore_dir"
    else
        sudo rm -rf "$restore_dir"

        ETCDCTL_API=3 sudo etcdctl snapshot restore "$snapshot_file" \
            --data-dir="$restore_dir" \
            --name="$(hostname)" \
            --initial-cluster="$(hostname)=https://127.0.0.1:2380" \
            --initial-cluster-token="etcd-cluster" \
            --initial-advertise-peer-urls="https://127.0.0.1:2380" 2>&1 | tee -a "$LOG_FILE"

        if [ $? -eq 0 ]; then
            log_success "Snapshot restored to: $restore_dir"

            # Replace old data
            log_info "Replacing etcd data directory..."
            sudo rm -rf /var/lib/etcd
            sudo mv "$restore_dir" /var/lib/etcd
            sudo chown -R root:root /var/lib/etcd

            log_success "etcd data directory updated"
        else
            log_error "Snapshot restore failed!"
            exit 1
        fi
    fi

    # Restart etcd
    log_info "Restarting etcd..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restart etcd"
    else
        sudo mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml
        sleep 30
    fi

    # Restart kube-apiserver
    log_info "Restarting kube-apiserver..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restart kube-apiserver"
    else
        sudo mv /tmp/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml
        sleep 30
    fi

    # Verify cluster
    log_info "Verifying cluster after restore..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if kubectl get nodes &> /dev/null; then
            log_success "Cluster is responding!"
            kubectl get nodes
            break
        fi
        ((retries++))
        echo -n "."
        sleep 10
    done

    if [ $retries -eq 30 ]; then
        log_error "Cluster did not come back online!"
        log_error "Manual intervention required"
        exit 1
    fi

    log_success "etcd restore completed successfully"
}

# Downgrade Kubernetes packages
downgrade_packages() {
    local target_version="$1"

    log_section "Downgrading Kubernetes Packages"

    log_warning "Package downgrade is risky and may cause issues!"
    log_info "Target version: $target_version"

    # Show current versions
    log_info "Current versions:"
    log_info "  kubeadm: $(kubeadm version -o short 2>/dev/null || echo 'Not found')"
    log_info "  kubelet: $(kubelet --version 2>/dev/null | awk '{print $2}' || echo 'Not found')"
    log_info "  kubectl: $(kubectl version --client --short 2>/dev/null | awk '{print $3}' || echo 'Not found')"

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi

    show_warning_banner
    echo ""
    if ! confirm_dangerous_operation "DOWNGRADE KUBERNETES PACKAGES TO $target_version"; then
        log_info "Downgrade cancelled"
        exit 0
    fi

    # Prepare package version
    local version_number="${target_version#v}"
    local pkg_version="${version_number}-*"
    local target_minor=$(echo "$target_version" | cut -d. -f2)

    # Downgrade based on OS
    case "$OS" in
        ubuntu|debian)
            log_info "Updating apt repository..."
            if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
                sudo sed -i "s|/v1\.[0-9]*/deb/|/v1.${target_minor}/deb/|g" /etc/apt/sources.list.d/kubernetes.list
            fi

            log_info "Unholding packages..."
            sudo apt-mark unhold kubeadm kubelet kubectl

            log_info "Downgrading packages..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubeadm=${pkg_version} kubelet=${pkg_version} kubectl=${pkg_version}"
            else
                sudo apt-get update
                sudo apt-get install -y --allow-downgrades \
                    kubeadm="${pkg_version}" \
                    kubelet="${pkg_version}" \
                    kubectl="${pkg_version}"
            fi

            log_info "Holding packages..."
            sudo apt-mark hold kubeadm kubelet kubectl
            ;;

        centos|rhel|fedora)
            log_info "Updating yum repository..."
            if [ -f /etc/yum.repos.d/kubernetes.repo ]; then
                sudo sed -i "s|/v1\.[0-9]*/rpm/|/v1.${target_minor}/rpm/|g" /etc/yum.repos.d/kubernetes.repo
            fi

            log_info "Downgrading packages..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY RUN] Would install: kubeadm-${pkg_version} kubelet-${pkg_version} kubectl-${pkg_version}"
            else
                sudo yum downgrade -y \
                    kubeadm-"${pkg_version}" \
                    kubelet-"${pkg_version}" \
                    kubectl-"${pkg_version}" \
                    --disableexcludes=kubernetes
            fi
            ;;

        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    # Restart kubelet
    log_info "Restarting kubelet..."
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would restart kubelet"
    else
        sudo systemctl daemon-reload
        sudo systemctl restart kubelet
    fi

    # Verify
    log_info "Verifying downgrade..."
    log_info "  kubeadm: $(kubeadm version -o short)"
    log_info "  kubelet: $(kubelet --version | awk '{print $2}')"
    log_info "  kubectl: $(kubectl version --client --short | awk '{print $3}')"

    log_success "Package downgrade completed"
    log_warning "You may need to run 'kubeadm upgrade node' or reconfigure the node"
}

# Restore cluster resources
restore_resources() {
    local backup_dir="$1"

    log_section "Restoring Cluster Resources"

    if [ ! -d "$backup_dir" ]; then
        log_error "Backup directory not found: $backup_dir"
        exit 1
    fi

    log_info "Backup directory: $backup_dir"
    log_info "Files in backup:"
    ls -lh "$backup_dir" | tee -a "$LOG_FILE"

    log_warning "Resource restoration may conflict with current state!"

    if ! confirm_dangerous_operation "RESTORE CLUSTER RESOURCES FROM $backup_dir"; then
        log_info "Restore cancelled"
        exit 0
    fi

    # Restore CRDs first
    if [ -f "$backup_dir/customresourcedefinitions.yaml" ]; then
        log_info "Restoring CRDs..."
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY RUN] Would apply CRDs"
        else
            kubectl apply -f "$backup_dir/customresourcedefinitions.yaml" 2>&1 | tee -a "$LOG_FILE" || log_warning "Some CRDs failed to restore"
        fi
    fi

    # Restore namespaced resources
    if [ -d "$backup_dir/namespaces" ]; then
        log_info "Restoring namespaced resources..."
        for ns_dir in "$backup_dir/namespaces"/*; do
            if [ -d "$ns_dir" ]; then
                local ns=$(basename "$ns_dir")
                log_info "Restoring namespace: $ns"

                if [ "$DRY_RUN" = "true" ]; then
                    log_info "[DRY RUN] Would restore resources for namespace: $ns"
                else
                    kubectl apply -f "$ns_dir/all-resources.yaml" 2>&1 | tee -a "$LOG_FILE" || log_warning "Some resources in $ns failed to restore"
                fi
            fi
        done
    fi

    log_success "Resource restore completed"
}

# Parse command line arguments
main() {
    log_section "Kubernetes Rollback Utility"
    log_info "Started at $(date)"
    log_info "Log file: $LOG_FILE"

    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi

    case "$1" in
        --help|-h)
            show_usage
            ;;
        --check-backups)
            check_backups
            ;;
        --list-etcd-snapshots)
            list_etcd_snapshots
            ;;
        --restore-etcd)
            if [ -z "${2:-}" ]; then
                log_error "Snapshot file not specified"
                echo "Usage: $0 --restore-etcd <snapshot-file>"
                exit 1
            fi
            check_control_plane
            restore_etcd_snapshot "$2"
            ;;
        --downgrade-packages)
            if [ -z "${2:-}" ]; then
                log_error "Target version not specified"
                echo "Usage: $0 --downgrade-packages <version>"
                exit 1
            fi
            downgrade_packages "$2"
            ;;
        --restore-resources)
            if [ -z "${2:-}" ]; then
                log_error "Backup directory not specified"
                echo "Usage: $0 --restore-resources <backup-directory>"
                exit 1
            fi
            restore_resources "$2"
            ;;
        --dry-run)
            DRY_RUN=true
            log_info "DRY RUN MODE ENABLED"
            shift
            main "$@"
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
