#!/usr/bin/env bash
# Modify VM resources (CPU/RAM/disk)
# AI uses this when user requests resource changes
set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/proxmox.sh
source "${SCRIPT_DIR}/lib/proxmox.sh"

usage() {
    cat <<EOF
Modify VM Resources

USAGE:
    $0 --vm <vmid> --pve <host> [OPTIONS]

OPTIONS:
    --vm <vmid>           VM ID to modify (required)
    --pve <host>          Proxmox host IP (required)
    --cpu <cores>         New CPU cores
    --ram <mb>            New RAM in MB
    --disk <gb>           Resize disk to GB (can only grow, not shrink)
    --help                Show this help

EXAMPLES:
    # Increase CPU and RAM
    $0 --vm 106 --pve 192.168.178.113 --cpu 8 --ram 16384

    # Add more disk space
    $0 --vm 106 --pve 192.168.178.113 --disk 200

    # Change all resources
    $0 --vm 106 --pve 192.168.178.113 --cpu 6 --ram 12288 --disk 150

AI USAGE:
    When user says: "Increase worker5 RAM to 16GB"
    AI executes: $0 --vm <worker5-vmid> --pve <host> --ram 16384
EOF
    exit 0
}

# Parse arguments
vmid=""
pve_host=""
cpu=""
ram_mb=""
disk_gb=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --vm) vmid="$2"; shift 2 ;;
        --pve) pve_host="$2"; shift 2 ;;
        --cpu) cpu="$2"; shift 2 ;;
        --ram) ram_mb="$2"; shift 2 ;;
        --disk) disk_gb="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate required params
if [ -z "$vmid" ] || [ -z "$pve_host" ]; then
    log_error "Missing required parameters: --vm and --pve"
    usage
fi

if [ -z "$cpu" ] && [ -z "$ram_mb" ] && [ -z "$disk_gb" ]; then
    log_error "No changes specified. Provide at least one of: --cpu, --ram, --disk"
    exit 1
fi

# Check if VM exists
log "Checking VM ${vmid} on $(hostname_from_ip "$pve_host")..."
if ! ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm status ${vmid}" &>/dev/null; then
    log_error "VM ${vmid} not found on $(hostname_from_ip "$pve_host")"
    exit 1
fi

# Get current VM status
vm_status=$(get_vm_status "$pve_host" "$vmid")
log "VM ${vmid} status: ${vm_status}"

# Get current config
log "Current configuration:"
ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm config ${vmid}" | grep -E "^(cores|memory|scsi0)" | while read -r line; do
    echo "  $line"
done

# Warn if VM is running
if [ "$vm_status" = "running" ]; then
    log_warning "VM is running. Changes require restart to take full effect."
    log_warning "CPU/RAM changes apply immediately but guest OS may need restart."
    log_warning "Disk changes apply immediately."
fi

# Apply changes
if [ -n "$cpu" ]; then
    log "Setting CPU cores to ${cpu}..."
    ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm set ${vmid} --cores ${cpu}" >/dev/null
    log_success "CPU updated to ${cpu} cores"
fi

if [ -n "$ram_mb" ]; then
    log "Setting RAM to ${ram_mb}MB..."
    ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm set ${vmid} --memory ${ram_mb}" >/dev/null
    log_success "RAM updated to ${ram_mb}MB ($((ram_mb / 1024))GB)"
fi

if [ -n "$disk_gb" ]; then
    log "Resizing disk to ${disk_gb}GB..."
    ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm resize ${vmid} scsi0 ${disk_gb}G" >/dev/null
    log_success "Disk resized to ${disk_gb}GB"
    log_warning "You may need to resize filesystem inside VM:"
    log_warning "  ssh to VM and run: sudo growpart /dev/sda 3 && sudo pvresize /dev/sda3 && sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && sudo resize2fs /dev/ubuntu-vg/ubuntu-lv"
fi

# Show new config
echo ""
log "New configuration:"
ssh -o StrictHostKeyChecking=no root@"$pve_host" "qm config ${vmid}" | grep -E "^(cores|memory|scsi0)" | while read -r line; do
    echo "  $line"
done

log_success "VM ${vmid} resources updated successfully"
