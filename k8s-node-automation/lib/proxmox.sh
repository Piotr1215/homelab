#!/usr/bin/env bash
# Proxmox VM Operations Library
# Used internally by AI for autonomous VM management
set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

# Proxmox hosts from environment
PVE1_HOST="${PROXMOX_HOST}"
PVE2_HOST="${PROXMOX2_HOST}"
PVE3_HOST="${PROXMOX3_HOST}"

# Ubuntu cloud image URL
UBUNTU_CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

# Create VM from Ubuntu cloud-init image
# Usage: create_vm <pve_host> <vmid> <name> <cores> <memory_mb> <disk_gb> [storage]
create_vm() {
    local pve_host=$1
    local vmid=$2
    local vm_name=$3
    local cores=$4
    local memory_mb=$5
    local disk_gb=$6
    local storage=${7:-local-lvm}

    log "Creating VM ${vmid} (${vm_name}) on $(hostname_from_ip "$pve_host")..."

    # Use cached cloud image or download once
    local cached_image="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
    local work_image="/tmp/noble-server-cloudimg-amd64-${vmid}.img"

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "if [ ! -f ${cached_image} ]; then \
            wget -q ${UBUNTU_CLOUD_IMAGE_URL} -O ${cached_image}; \
        fi && \
        cp ${cached_image} ${work_image}"

    # Resize working copy
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qemu-img resize ${work_image} ${disk_gb}G"

    # Create VM
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm create ${vmid} --name ${vm_name} --ostype l26 \
        --memory ${memory_mb} \
        --agent 1 \
        --bios ovmf --machine q35 --efidisk0 ${storage}:0,pre-enrolled-keys=0 \
        --cpu host --sockets 1 --cores ${cores} \
        --vga serial0 --serial0 socket \
        --net0 virtio,bridge=vmbr0" >/dev/null

    # Import disk
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm importdisk ${vmid} ${work_image} ${storage}" >/dev/null

    # Configure disk and boot
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm set ${vmid} --scsihw virtio-scsi-pci --virtio0 ${storage}:vm-${vmid}-disk-1,discard=on && \
        qm set ${vmid} --boot order=virtio0 && \
        qm set ${vmid} --scsi1 ${storage}:cloudinit" >/dev/null

    # Create cloud-init vendor config for Kubespray prerequisites
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "mkdir -p /var/lib/vz/snippets && cat > /var/lib/vz/snippets/kubespray-prep-${vmid}.yaml << 'CLOUDEOF'
#cloud-config
users:
  - name: decoder
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub)
package_update: true
packages:
  - python3
  - python3-pip
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
CLOUDEOF
"

    # Configure cloud-init
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm set ${vmid} --cicustom 'user=local:snippets/kubespray-prep-${vmid}.yaml' && \
        qm set ${vmid} --ipconfig0 ip=dhcp" >/dev/null 2>&1 || true

    # Cleanup working copy (keep cached image)
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" "rm -f ${work_image}"

    log_success "VM ${vmid} (${vm_name}) created successfully"
}

# Get free resources on Proxmox host
# Returns: free_memory_gb free_storage_gb
# Usage: get_pve_free_resources <pve_host>
get_pve_free_resources() {
    local pve_host=$1
    local node_name

    # Get node name (pve or pve2)
    node_name=$(ssh -o StrictHostKeyChecking=no root@"${pve_host}" "hostname")

    # Get memory info using Python JSON parsing (bytes)
    local mem_values
    mem_values=$(ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "pvesh get /nodes/${node_name}/status --output-format json" | \
        python3 -c "import sys, json; d=json.load(sys.stdin); print(d['memory']['free'], d['memory']['total'])")

    local free_mem
    free_mem=$(echo "$mem_values" | awk '{print $1}')
    local free_mem_gb=$(( free_mem / 1024 / 1024 / 1024 ))

    # Get storage info using Python JSON parsing (bytes)
    local storage_values
    storage_values=$(ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "pvesh get /nodes/${node_name}/storage/local-lvm/status --output-format json" | \
        python3 -c "import sys, json; d=json.load(sys.stdin); print(d['avail'], d['total'])")

    local avail_storage
    avail_storage=$(echo "$storage_values" | awk '{print $1}')
    local free_storage_gb=$(( avail_storage / 1024 / 1024 / 1024 ))

    echo "${free_mem_gb} ${free_storage_gb}"
}

# Choose best Proxmox host based on free resources
# Returns: pve_host (IP address)
# Usage: choose_optimal_pve_host [required_mem_gb] [required_disk_gb]
choose_optimal_pve_host() {
    local required_mem=${1:-8}    # Default 8GB
    local required_disk=${2:-100} # Default 100GB

    log "Checking resources on Proxmox hosts..."

    # Get resources from both hosts
    local pve1_resources
    local pve2_resources
    pve1_resources=$(get_pve_free_resources "$PVE1_HOST" 2>/dev/null || echo "0 0")
    pve2_resources=$(get_pve_free_resources "$PVE2_HOST" 2>/dev/null || echo "0 0")

    local pve1_mem=$(echo "$pve1_resources" | awk '{print $1}')
    local pve1_disk=$(echo "$pve1_resources" | awk '{print $2}')
    local pve2_mem=$(echo "$pve2_resources" | awk '{print $1}')
    local pve2_disk=$(echo "$pve2_resources" | awk '{print $2}')

    print_info "PVE1 Free" "${pve1_mem}GB RAM, ${pve1_disk}GB disk"
    print_info "PVE2 Free" "${pve2_mem}GB RAM, ${pve2_disk}GB disk"

    # Check if requirements can be met
    local pve1_ok=0
    local pve2_ok=0

    if [ "$pve1_mem" -ge "$required_mem" ] && [ "$pve1_disk" -ge "$required_disk" ]; then
        pve1_ok=1
    fi

    if [ "$pve2_mem" -ge "$required_mem" ] && [ "$pve2_disk" -ge "$required_disk" ]; then
        pve2_ok=1
    fi

    # Choose host with most free resources (prefer memory)
    if [ $pve1_ok -eq 0 ] && [ $pve2_ok -eq 0 ]; then
        log_error "Neither PVE host has sufficient resources (need ${required_mem}GB RAM, ${required_disk}GB disk)"
        return 1
    elif [ $pve1_ok -eq 1 ] && [ $pve2_ok -eq 0 ]; then
        echo "$PVE1_HOST"
    elif [ $pve1_ok -eq 0 ] && [ $pve2_ok -eq 1 ]; then
        echo "$PVE2_HOST"
    else
        # Both OK, choose one with more free memory
        if [ "$pve1_mem" -ge "$pve2_mem" ]; then
            echo "$PVE1_HOST"
        else
            echo "$PVE2_HOST"
        fi
    fi
}

# Clone VM from source
# Usage: clone_vm <pve_host> <source_vmid> <new_vmid> <new_name>
clone_vm() {
    local pve_host=$1
    local source_vmid=$2
    local new_vmid=$3
    local new_name=$4

    log "Cloning VM ${source_vmid} → ${new_vmid} (${new_name}) on $(hostname_from_ip "$pve_host")..."

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm clone ${source_vmid} ${new_vmid} --name ${new_name}" >/dev/null

    log_success "VM ${new_vmid} cloned successfully"
}

# Configure VM resources
# Usage: configure_vm <pve_host> <vmid> <cores> <memory_mb> <disk_gb> [ip] [hostname]
configure_vm() {
    local pve_host=$1
    local vmid=$2
    local cores=$3
    local memory_mb=$4
    local disk_gb=$5
    local ip=${6:-}
    local hostname=${7:-}

    log "Configuring VM ${vmid}: ${cores} cores, ${memory_mb}MB RAM, ${disk_gb}GB disk..."

    # Enable hotplug for all resources (allows live RAM/CPU changes without reboot)
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm set ${vmid} --hotplug network,disk,cpu,memory,usb" >/dev/null

    # Set CPU and memory
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm set ${vmid} --cores ${cores} --memory ${memory_mb}" >/dev/null

    # Resize disk (SCSI0)
    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm resize ${vmid} scsi0 ${disk_gb}G" >/dev/null

    # Configure network if IP provided
    if [ -n "$ip" ]; then
        log "Setting static IP: ${ip}/24"
        ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
            "qm set ${vmid} --ipconfig0 ip=${ip}/24,gw=192.168.178.1" >/dev/null
    fi

    # Set hostname via cloud-init if provided
    if [ -n "$hostname" ]; then
        log "Setting hostname: ${hostname}"
        ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
            "qm set ${vmid} --ciuser decoder --cipassword $(openssl rand -base64 12)" >/dev/null 2>&1 || true
    fi

    log_success "VM ${vmid} configured"
}

# Start VM
# Usage: start_vm <pve_host> <vmid>
start_vm() {
    local pve_host=$1
    local vmid=$2

    log "Starting VM ${vmid}..."

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm start ${vmid}" >/dev/null

    log_success "VM ${vmid} started"
}

# Stop VM
# Usage: stop_vm <pve_host> <vmid>
stop_vm() {
    local pve_host=$1
    local vmid=$2

    log "Stopping VM ${vmid}..."

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm shutdown ${vmid}" >/dev/null

    log_success "VM ${vmid} stopped"
}

# Delete VM
# Usage: delete_vm <pve_host> <vmid>
delete_vm() {
    local pve_host=$1
    local vmid=$2

    log_warning "Deleting VM ${vmid}..."

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm destroy ${vmid}" >/dev/null

    log_success "VM ${vmid} deleted"
}

# Get VM status
# Usage: get_vm_status <pve_host> <vmid>
get_vm_status() {
    local pve_host=$1
    local vmid=$2

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" \
        "qm status ${vmid}" | awk '{print $2}'
}

# Get hostname from PVE IP
# Usage: hostname_from_ip <ip>
hostname_from_ip() {
    case "$1" in
        "$PVE1_HOST") echo "pve" ;;
        "$PVE2_HOST") echo "pve2" ;;
        "$PVE3_HOST") echo "pve3" ;;
        *) echo "unknown" ;;
    esac
}

# List all VMs on host
# Usage: list_vms <pve_host>
list_vms() {
    local pve_host=$1

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" "qm list"
}

# Get VM config
# Usage: get_vm_config <pve_host> <vmid>
get_vm_config() {
    local pve_host=$1
    local vmid=$2

    ssh -o StrictHostKeyChecking=no root@"${pve_host}" "qm config ${vmid}"
}
