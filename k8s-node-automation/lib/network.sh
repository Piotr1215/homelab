#!/usr/bin/env bash
# Network Utilities - IP/Hostname Allocation
# Used internally by AI for autonomous network configuration
set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

# Network configuration
NETWORK_PREFIX="192.168.178"
GATEWAY="${NETWORK_PREFIX}.1"
METALLB_POOL_START=90
METALLB_POOL_END=105
DHCP_POOL_START=120
DHCP_POOL_END=200

# Get all IPs currently in use (nodes + services)
# Usage: get_used_ips
get_used_ips() {
    {
        # Get node IPs
        kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
        echo " "
        # Get LoadBalancer IPs
        kubectl get svc -A --field-selector spec.type=LoadBalancer -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    } | tr ' ' '\n' | grep -E "^${NETWORK_PREFIX}\." | sort -V | uniq
}

# Get IP from DHCP after VM boots
# VMs use DHCP pool (120-200), no manual allocation needed
# Usage: get_vm_ip <hostname>
get_vm_ip() {
    local hostname=$1

    # Wait for VM to get IP via DHCP and register in cluster
    log "Waiting for ${hostname} to get DHCP IP and register..."

    local attempts=0
    local max_attempts=60  # 2 minutes

    while [ $attempts -lt $max_attempts ]; do
        local ip
        ip=$(kubectl get node "$hostname" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

        if [ -n "$ip" ]; then
            log_success "${hostname} has IP: ${ip}"
            echo "$ip"
            return 0
        fi

        sleep 2
        attempts=$((attempts + 1))
    done

    log_error "Failed to get IP for ${hostname}"
    return 1
}

# Get next worker hostname
# Usage: get_next_worker_name
get_next_worker_name() {
    log "Finding next worker hostname..."

    # Get all worker numbers
    local worker_numbers
    worker_numbers=$(kubectl get nodes -o name 2>/dev/null | \
        grep 'kube-worker' | \
        sed 's|node/kube-worker||' | \
        sort -n)

    # Find highest number
    local max_worker=0
    if [ -n "$worker_numbers" ]; then
        max_worker=$(echo "$worker_numbers" | tail -1)
    fi

    # Next worker number
    local next_num=$((max_worker + 1))
    local next_name="kube-worker${next_num}"

    log_success "Next hostname: ${next_name}"
    echo "$next_name"
}

# Validate IP is not in MetalLB pool range
# Usage: validate_ip_not_in_pool <ip>
validate_ip_not_in_pool() {
    local ip=$1
    local ip_suffix

    ip_suffix=$(echo "$ip" | cut -d. -f4)

    if [ "$ip_suffix" -ge $METALLB_POOL_START ] && [ "$ip_suffix" -le $METALLB_POOL_END ]; then
        log_error "IP ${ip} is in MetalLB pool range (${NETWORK_PREFIX}.${METALLB_POOL_START}-${METALLB_POOL_END})"
        log_error "Worker IPs must be outside this range"
        return 1
    fi

    return 0
}

# Validate IP is in DHCP range
# Usage: validate_ip_in_dhcp_range <ip>
validate_ip_in_dhcp_range() {
    local ip=$1
    local ip_suffix

    ip_suffix=$(echo "$ip" | cut -d. -f4)

    if [ "$ip_suffix" -lt $DHCP_POOL_START ] || [ "$ip_suffix" -gt $DHCP_POOL_END ]; then
        log_warning "IP ${ip} is outside DHCP pool range (${NETWORK_PREFIX}.${DHCP_POOL_START}-${DHCP_POOL_END})"
        return 1
    fi

    return 0
}

# Get IP from hostname (lookup in cluster)
# Usage: get_ip_from_hostname <hostname>
get_ip_from_hostname() {
    local hostname=$1

    kubectl get node "$hostname" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

# Get hostname from IP (lookup in cluster)
# Usage: get_hostname_from_ip <ip>
get_hostname_from_ip() {
    local ip=$1

    kubectl get nodes -o json 2>/dev/null | \
        jq -r ".items[] | select(.status.addresses[] | select(.type==\"InternalIP\" and .address==\"${ip}\")) | .metadata.name"
}

# Check if hostname already exists in cluster
# Usage: hostname_exists <hostname>
hostname_exists() {
    local hostname=$1

    kubectl get node "$hostname" &>/dev/null
}

# Print network allocation summary
# Usage: print_network_summary
print_network_summary() {
    echo ""
    log "Network Allocation Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    print_info "Network" "${NETWORK_PREFIX}.0/24"
    print_info "Gateway" "$GATEWAY"
    print_info "MetalLB Pool" "${NETWORK_PREFIX}.${METALLB_POOL_START}-${METALLB_POOL_END} (LoadBalancer services)"
    print_info "DHCP Pool" "${NETWORK_PREFIX}.${DHCP_POOL_START}-${DHCP_POOL_END} (Worker nodes via DHCP)"

    echo ""
    print_info "Current Nodes" ""
    kubectl get nodes -o wide 2>/dev/null | awk 'NR==1 || /kube-/ {print "  "$1" - "$6}' || echo "  (kubectl not available)"

    echo ""
    print_info "Used IPs" "$(get_used_ips | wc -l) total"

    local next_name
    next_name=$(get_next_worker_name 2>/dev/null || echo "kube-worker1")
    print_info "Next Hostname" "$next_name"
    print_info "IP Allocation" "DHCP (automatic from ${NETWORK_PREFIX}.${DHCP_POOL_START}-${DHCP_POOL_END})"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}
