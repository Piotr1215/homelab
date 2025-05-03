# VM Provisioning for Kubernetes Cluster

## Proxmox Template Creation

Creating a template VM in Proxmox will save you time when deploying multiple nodes.

### 1. Create Base Template VM

```bash
# SSH into your Proxmox server
ssh root@192.168.178.75

# Download Ubuntu Server 22.04 LTS
cd /var/lib/vz/template/iso
wget https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso

# Create a new VM for the template
qm create 9000 --name "ubuntu-2204-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm set 9000 --scsi0 local-lvm:32G
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local:iso/ubuntu-22.04.3-live-server-amd64.iso,media=cdrom
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
```

### 2. Install Ubuntu on the Template VM

1. Start the VM and connect to the console
   ```bash
   qm start 9000
   qm terminal 9000
   ```

2. Follow the Ubuntu installation process:
   - Choose your language and keyboard layout
   - Configure the network (select DHCP for now)
   - Set up a hostname like "k8s-template"
   - Create a user (e.g., "k8s-admin")
   - Install OpenSSH server when prompted
   - Minimize other software installations

3. After installation, log in and update the system:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

4. Install cloud-init and qemu-guest-agent:
   ```bash
   sudo apt install -y cloud-init qemu-guest-agent
   sudo systemctl enable qemu-guest-agent
   ```

5. Configure cloud-init:
   ```bash
   sudo vim /etc/cloud/cloud.cfg
   ```
   
   Ensure these settings are configured:
   ```yaml
   preserve_hostname: false
   manage_etc_hosts: true
   ```

6. Clean up for template preparation:
   ```bash
   sudo apt clean
   sudo apt autoremove -y
   sudo rm -f /etc/ssh/ssh_host_*
   sudo rm -f /etc/netplan/*.yaml
   sudo rm -f /etc/machine-id
   sudo touch /etc/machine-id
   sudo cloud-init clean
   sudo shutdown now
   ```

### 3. Convert VM to Template

```bash
qm set 9000 --delete ide2
qm template 9000
```

## Deploying Kubernetes VMs from Template

### 1. Create Control Plane Node

```bash
# Clone the template for the control plane (with more resources)
qm clone 9000 101 --name k8s-control --full

# Set VM resources for control plane
qm set 101 --memory 4096 --cores 4
qm set 101 --ipconfig0 ip=192.168.178.101/24,gw=192.168.178.1
qm set 101 --sshkey ~/.ssh/id_rsa.pub
qm set 101 --ciuser your-username

# Start the VM
qm start 101
```

### 2. Create Worker Nodes

```bash
# Create worker nodes (repeat for multiple workers)
qm clone 9000 102 --name k8s-worker1 --full
qm set 102 --memory 4096 --cores 2
qm set 102 --ipconfig0 ip=192.168.178.102/24,gw=192.168.178.1
qm set 102 --sshkey ~/.ssh/id_rsa.pub
qm set 102 --ciuser your-username

qm clone 9000 103 --name k8s-worker2 --full
qm set 103 --memory 4096 --cores 2
qm set 103 --ipconfig0 ip=192.168.178.103/24,gw=192.168.178.1
qm set 103 --sshkey ~/.ssh/id_rsa.pub
qm set 103 --ciuser your-username

# Start the worker VMs
qm start 102
qm start 103
```

## Post-Deployment Configuration

### 1. Update hostnames and hosts files

On each node, set the appropriate hostname:

```bash
# On control plane
sudo hostnamectl set-hostname k8s-control

# On worker1
sudo hostnamectl set-hostname k8s-worker1

# On worker2
sudo hostnamectl set-hostname k8s-worker2
```

### 2. Update /etc/hosts on all nodes

Add entries for all Kubernetes nodes to `/etc/hosts` on each VM:

```
192.168.178.101 k8s-control
192.168.178.102 k8s-worker1
192.168.178.103 k8s-worker2
```

### 3. Verify SSH access between nodes

Ensure you can SSH from your workstation to all nodes without password prompts.

## Next Steps

Once your VMs are deployed and configured, you can proceed with the Kubernetes installation steps from the `kubeadm-setup.md` file:

1. Prepare all nodes by installing containerd, kubeadm, kubectl, etc.
2. Initialize the control plane node
3. Join the worker nodes to the cluster

---

## Using Terraform with Proxmox (Alternative Approach)

If you prefer infrastructure as code, you can use Terraform with the Proxmox provider to automate VM deployment.

First, install Terraform on your local machine, then create a configuration like this:

```terraform
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.11"
    }
  }
}

provider "proxmox" {
  pm_api_url      = "https://192.168.178.75:8006/api2/json"
  pm_tls_insecure = true
}

resource "proxmox_vm_qemu" "k8s_control" {
  name        = "k8s-control"
  target_node = "proxmox"
  clone       = "ubuntu-2204-template"
  full_clone  = true

  cores   = 4
  sockets = 1
  memory  = 4096
  agent   = 1

  network {
    bridge = "vmbr0"
    model  = "virtio"
  }

  ipconfig0 = "ip=192.168.178.101/24,gw=192.168.178.1"
  sshkeys   = file("~/.ssh/id_rsa.pub")
  ciuser    = "your-username"
}

# Define similar resources for worker nodes
resource "proxmox_vm_qemu" "k8s_worker1" {
  name        = "k8s-worker1"
  target_node = "proxmox"
  clone       = "ubuntu-2204-template"
  full_clone  = true

  cores   = 2
  sockets = 1
  memory  = 4096
  agent   = 1

  network {
    bridge = "vmbr0"
    model  = "virtio"
  }

  ipconfig0 = "ip=192.168.178.102/24,gw=192.168.178.1"
  sshkeys   = file("~/.ssh/id_rsa.pub")
  ciuser    = "your-username"
}

resource "proxmox_vm_qemu" "k8s_worker2" {
  name        = "k8s-worker2"
  target_node = "proxmox"
  clone       = "ubuntu-2204-template"
  full_clone  = true

  cores   = 2
  sockets = 1
  memory  = 4096
  agent   = 1

  network {
    bridge = "vmbr0"
    model  = "virtio"
  }

  ipconfig0 = "ip=192.168.178.103/24,gw=192.168.178.1"
  sshkeys   = file("~/.ssh/id_rsa.pub")
  ciuser    = "your-username"
}
```

Save this as `main.tf`, then run:

```bash
terraform init
terraform plan
terraform apply
```