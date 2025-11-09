#!/usr/bin/env bash
# Common Utilities for K8s Node Automation
# Used internally by AI for autonomous operations
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $*" >&2
}

# Wait for SSH to become available
# Usage: wait_for_ssh <ip> [timeout_seconds]
wait_for_ssh() {
    local ip=$1
    local timeout=${2:-300}  # Default 5 minutes
    local elapsed=0
    local interval=5

    log "Waiting for SSH on ${ip}..."

    while [ $elapsed -lt $timeout ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes decoder@"${ip}" "exit" 2>/dev/null; then
            log_success "SSH ready on ${ip}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    log_error "SSH timeout after ${timeout}s on ${ip}"
    return 1
}

# Wait for cloud-init to complete
# Usage: wait_for_cloud_init <ip> [timeout_seconds]
wait_for_cloud_init() {
    local ip=$1
    local timeout=${2:-600}  # Default 10 minutes (cloud-init can be slow)
    local elapsed=0
    local interval=10

    log "Waiting for cloud-init to complete on ${ip}..."

    while [ $elapsed -lt $timeout ]; do
        # Check if cloud-init status shows "done" or "disabled"
        if ssh -o StrictHostKeyChecking=no decoder@"${ip}" "cloud-init status 2>/dev/null | grep -qE 'status: done|status: disabled'" 2>/dev/null; then
            log_success "Cloud-init completed on ${ip}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    log_error "Cloud-init timeout after ${timeout}s on ${ip}"
    return 1
}

# Wait for file to exist on remote host
# Usage: wait_for_file <ip> <file_path> [timeout_seconds]
wait_for_file() {
    local ip=$1
    local file_path=$2
    local timeout=${3:-120}
    local elapsed=0
    local interval=5

    log "Waiting for ${file_path} on ${ip}..."

    while [ $elapsed -lt $timeout ]; do
        if ssh -o StrictHostKeyChecking=no decoder@"${ip}" "test -f '${file_path}'" 2>/dev/null; then
            log_success "File ${file_path} exists on ${ip}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    log_error "File ${file_path} not found after ${timeout}s on ${ip}"
    return 1
}

# Check if command exists on remote host
# Usage: remote_command_exists <ip> <command>
remote_command_exists() {
    local ip=$1
    local cmd=$2

    ssh -o StrictHostKeyChecking=no decoder@"${ip}" "command -v ${cmd}" &>/dev/null
}

# Execute command with retry
# Usage: retry <max_attempts> <command> [args...]
retry() {
    local max_attempts=$1
    shift
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        log_warning "Attempt ${attempt}/${max_attempts} failed, retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done

    log_error "Failed after ${max_attempts} attempts"
    return 1
}

# Validate IP address format
# Usage: validate_ip <ip>
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Check if IP is in use (ping + SSH check)
# Usage: ip_in_use <ip>
ip_in_use() {
    local ip=$1

    # Quick ping check
    if ping -c 1 -W 1 "$ip" &>/dev/null; then
        return 0
    fi

    # SSH check (more reliable for hosts that don't respond to ping)
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o BatchMode=yes decoder@"$ip" "exit" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Get next available VM ID on Proxmox host
# Usage: get_next_vmid <pve_host>
get_next_vmid() {
    local pve_host=$1
    local max_vmid

    max_vmid=$(ssh -o StrictHostKeyChecking=no root@"${pve_host}" "qm list" | awk 'NR>1 {print $1}' | sort -n | tail -1)

    # Start from 106 (after existing workers), or max+1
    local next_vmid=$((max_vmid + 1))
    if [ "$next_vmid" -lt 106 ]; then
        next_vmid=106
    fi

    echo "$next_vmid"
}

# Pretty print key-value pairs
# Usage: print_info "Key" "Value"
print_info() {
    printf "${BLUE}%-20s${NC}: %s\n" "$1" "$2"
}

# Confirm action (non-interactive, always returns true for AI use)
# Usage: confirm "message"
confirm() {
    # AI operations are autonomous, no confirmation needed
    return 0
}
