#!/usr/bin/env bash
# Kubernetes Automation Orchestration Script
# Schedules and coordinates all maintenance tasks
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/k8s-maintenance}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
AUTOMATION_LOG="${LOG_DIR}/automation-${TIMESTAMP}.log"

# Task scheduling configuration
DAILY_TASKS=("health-check" "cleanup")
WEEKLY_TASKS=("cert-check")
MONTHLY_TASKS=("etcd-backup")

# Email notification settings
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-false}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-admin@example.com}"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${AUTOMATION_LOG}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${AUTOMATION_LOG}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${AUTOMATION_LOG}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${AUTOMATION_LOG}"
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Kubernetes automation orchestration and scheduling tool.

COMMANDS:
    schedule            Install cron jobs for automated maintenance
    unschedule          Remove cron jobs
    run-daily           Execute daily maintenance tasks
    run-weekly          Execute weekly maintenance tasks
    run-monthly         Execute monthly maintenance tasks
    status              Show automation status
    help                Show this help message

OPTIONS:
    --notify            Enable email notifications
    --email <address>   Set notification email address

EXAMPLES:
    $0 schedule                     # Install cron jobs
    $0 run-daily                    # Run daily tasks manually
    $0 schedule --notify --email admin@k8s.local

SCHEDULED TASKS:
    Daily (2:00 AM):
        - Cluster health check
        - Resource cleanup (dry-run)

    Weekly (Sunday 3:00 AM):
        - Certificate expiration check
        - Node status validation
        - Resource cleanup (execute)

    Monthly (1st day 4:00 AM):
        - etcd backup
        - Full cluster validation

CRON SCHEDULE:
    0 2 * * *       Daily tasks
    0 3 * * 0       Weekly tasks (Sunday)
    0 4 1 * *       Monthly tasks (1st of month)
EOF
    exit 0
}

# Send notification
send_notification() {
    local subject=$1
    local message=$2

    if [[ "${ENABLE_NOTIFICATIONS}" != "true" ]]; then
        return 0
    fi

    log_info "Sending notification to ${NOTIFICATION_EMAIL}"

    if command -v mail &> /dev/null; then
        echo "${message}" | mail -s "${subject}" "${NOTIFICATION_EMAIL}"
        log_success "Notification sent"
    else
        log_warning "mail command not found, notification not sent"
    fi
}

# Execute task with error handling
execute_task() {
    local task_name=$1
    local task_script=$2
    shift 2
    local task_args="$*"

    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Executing task: ${task_name}"
    log_info "Script: ${task_script}"
    log_info "Arguments: ${task_args}"
    log_info "═══════════════════════════════════════════════════════════════"

    local start_time=$(date +%s)
    local task_log="${LOG_DIR}/${task_name}-${TIMESTAMP}.log"

    if bash "${SCRIPT_DIR}/${task_script}" ${task_args} &> "${task_log}"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Task '${task_name}' completed successfully in ${duration}s"
        log_info "Task log: ${task_log}"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_error "Task '${task_name}' failed after ${duration}s"
        log_error "Check log: ${task_log}"

        # Send failure notification
        send_notification "K8s Task Failed: ${task_name}" \
            "Task: ${task_name}\nStatus: FAILED\nDuration: ${duration}s\nLog: ${task_log}"

        return 1
    fi
}

# Run daily maintenance tasks
run_daily() {
    log_info "Starting daily maintenance tasks..."

    local failed=0

    # Health check
    execute_task "health-check" "k8s-health-check.sh" || ((failed++))

    # Cleanup (dry-run only for daily)
    DRY_RUN=true execute_task "cleanup-dry-run" "k8s-cleanup.sh" "--all" || ((failed++))

    # Summary
    if [[ ${failed} -eq 0 ]]; then
        log_success "All daily tasks completed successfully"
        send_notification "K8s Daily Maintenance: Success" \
            "All daily maintenance tasks completed successfully.\nTimestamp: ${TIMESTAMP}"
    else
        log_error "${failed} daily task(s) failed"
        send_notification "K8s Daily Maintenance: Failed" \
            "${failed} task(s) failed during daily maintenance.\nCheck logs: ${LOG_DIR}"
    fi
}

# Run weekly maintenance tasks
run_weekly() {
    log_info "Starting weekly maintenance tasks..."

    local failed=0

    # Certificate check
    execute_task "cert-check" "k8s-cert-manager.sh" "check" || ((failed++))

    # Full health check
    execute_task "health-check" "k8s-health-check.sh" "-v" || ((failed++))

    # Cleanup (execute mode)
    DRY_RUN=false execute_task "cleanup-execute" "k8s-cleanup.sh" \
        "--completed-jobs" "--failed-pods" "--evicted-pods" || ((failed++))

    # Summary
    if [[ ${failed} -eq 0 ]]; then
        log_success "All weekly tasks completed successfully"
        send_notification "K8s Weekly Maintenance: Success" \
            "All weekly maintenance tasks completed successfully.\nTimestamp: ${TIMESTAMP}"
    else
        log_error "${failed} weekly task(s) failed"
        send_notification "K8s Weekly Maintenance: Failed" \
            "${failed} task(s) failed during weekly maintenance.\nCheck logs: ${LOG_DIR}"
    fi
}

# Run monthly maintenance tasks
run_monthly() {
    log_info "Starting monthly maintenance tasks..."

    local failed=0

    # etcd backup
    execute_task "etcd-backup" "k8s-etcd-backup.sh" || ((failed++))

    # Certificate backup
    execute_task "cert-backup" "k8s-cert-manager.sh" "backup" || ((failed++))

    # Full cleanup with all options
    DRY_RUN=false execute_task "full-cleanup" "k8s-cleanup.sh" "--all" || ((failed++))

    # Comprehensive health check
    execute_task "full-health-check" "k8s-health-check.sh" "-v" || ((failed++))

    # Summary
    if [[ ${failed} -eq 0 ]]; then
        log_success "All monthly tasks completed successfully"
        send_notification "K8s Monthly Maintenance: Success" \
            "All monthly maintenance tasks completed successfully.\nTimestamp: ${TIMESTAMP}"
    else
        log_error "${failed} monthly task(s) failed"
        send_notification "K8s Monthly Maintenance: Failed" \
            "${failed} task(s) failed during monthly maintenance.\nCheck logs: ${LOG_DIR}"
    fi
}

# Install cron jobs
install_cron() {
    log_info "Installing cron jobs for automated maintenance..."

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_warning "Not running as root. User crontab will be used."
    fi

    # Create cron job entries
    local cron_file="/tmp/k8s-automation-cron-${TIMESTAMP}"

    cat > "${cron_file}" <<EOF
# Kubernetes Automated Maintenance Tasks
# Generated by k8s-automation.sh on ${TIMESTAMP}

# Daily tasks at 2:00 AM
0 2 * * * ${SCRIPT_DIR}/k8s-automation.sh run-daily >> ${LOG_DIR}/cron-daily.log 2>&1

# Weekly tasks on Sunday at 3:00 AM
0 3 * * 0 ${SCRIPT_DIR}/k8s-automation.sh run-weekly >> ${LOG_DIR}/cron-weekly.log 2>&1

# Monthly tasks on 1st day at 4:00 AM
0 4 1 * * ${SCRIPT_DIR}/k8s-automation.sh run-monthly >> ${LOG_DIR}/cron-monthly.log 2>&1
EOF

    log_info "Cron job configuration:"
    cat "${cron_file}" | tee -a "${AUTOMATION_LOG}"
    echo ""

    # Backup existing crontab
    if crontab -l &> /dev/null; then
        crontab -l > "${LOG_DIR}/crontab-backup-${TIMESTAMP}"
        log_info "Existing crontab backed up to: ${LOG_DIR}/crontab-backup-${TIMESTAMP}"
    fi

    # Install new cron jobs
    (crontab -l 2>/dev/null | grep -v "k8s-automation.sh" || true; cat "${cron_file}") | crontab -

    if [[ $? -eq 0 ]]; then
        log_success "Cron jobs installed successfully"
        rm -f "${cron_file}"
    else
        log_error "Failed to install cron jobs"
        rm -f "${cron_file}"
        return 1
    fi

    # Verify installation
    log_info "Installed cron jobs:"
    crontab -l | grep "k8s-automation" | tee -a "${AUTOMATION_LOG}"
}

# Remove cron jobs
uninstall_cron() {
    log_info "Removing Kubernetes automation cron jobs..."

    # Backup existing crontab
    if crontab -l &> /dev/null; then
        crontab -l > "${LOG_DIR}/crontab-backup-${TIMESTAMP}"
        log_info "Existing crontab backed up to: ${LOG_DIR}/crontab-backup-${TIMESTAMP}"
    fi

    # Remove k8s-automation entries
    crontab -l 2>/dev/null | grep -v "k8s-automation.sh" | crontab -

    if [[ $? -eq 0 ]]; then
        log_success "Cron jobs removed successfully"
    else
        log_error "Failed to remove cron jobs"
        return 1
    fi
}

# Show automation status
show_status() {
    log_info "Kubernetes Automation Status"
    echo ""

    # Check if cron jobs are installed
    log_info "Cron jobs:"
    if crontab -l 2>/dev/null | grep -q "k8s-automation"; then
        crontab -l | grep "k8s-automation" | tee -a "${AUTOMATION_LOG}"
        log_success "Automation is scheduled"
    else
        log_warning "No cron jobs found. Run '$0 schedule' to install."
    fi
    echo ""

    # Check available scripts
    log_info "Available maintenance scripts:"
    for script in k8s-etcd-backup.sh k8s-etcd-restore.sh k8s-cert-manager.sh \
                  k8s-node-maintenance.sh k8s-health-check.sh k8s-cleanup.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            if [[ -x "${SCRIPT_DIR}/${script}" ]]; then
                log_success "${script} (executable)"
            else
                log_warning "${script} (not executable)"
            fi
        else
            log_error "${script} (not found)"
        fi
    done
    echo ""

    # Recent logs
    log_info "Recent maintenance logs:"
    ls -lht "${LOG_DIR}"/*.log 2>/dev/null | head -10 | tee -a "${AUTOMATION_LOG}" || \
        log_info "No logs found in ${LOG_DIR}"
}

# Main execution
main() {
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}     ⚙️  Kubernetes Automation Orchestrator ⚙️                 ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local command="${1:-help}"

    # Parse options
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --notify)
                ENABLE_NOTIFICATIONS=true
                shift
                ;;
            --email)
                NOTIFICATION_EMAIL="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "${command}" in
        schedule)
            install_cron
            ;;
        unschedule)
            uninstall_cron
            ;;
        run-daily)
            run_daily
            ;;
        run-weekly)
            run_weekly
            ;;
        run-monthly)
            run_monthly
            ;;
        status)
            show_status
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
    log_info "Automation log: ${AUTOMATION_LOG}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
}

# Run main function
main "$@"
