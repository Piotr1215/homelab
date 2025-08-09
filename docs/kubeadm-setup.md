# Setting Up Kubernetes with kubeadm on VMs

## VM Requirements

### Control Plane Node(s)
- **CPU**: 2+ cores
- **RAM**: 4+ GB
- **Storage**: 50+ GB
- **OS**: Ubuntu 22.04 LTS (or your preferred Linux distro)

### Worker Nodes
- **CPU**: 2+ cores
- **RAM**: 2+ GB (depending on workload)
- **Storage**: 50+ GB
- **OS**: Same as control plane for consistency

## Network Planning
- **Pod CIDR**: 10.244.0.0/16 (can reuse from current setup)
- **Service CIDR**: 10.96.0.0/12 (can reuse from current setup)
- **Node IPs**: Static IPs for all nodes
- **Load Balancer**: Consider MetalLB for bare metal load balancing

## Installation Steps

### 1. Prepare All Nodes

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set up required networking parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Install containerd
sudo apt install -y containerd

# Configure containerd to use systemd cgroups
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install kubeadm, kubelet, and kubectl
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Disable swap (required for Kubernetes)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
```

### 2. Initialize Control Plane

On the control plane node only:

```bash
# Initialize the control plane
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12 --kubernetes-version=v1.29.0

# Set up kubeconfig for the user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install a CNI (Container Network Interface) - using Calico in this example
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

### 3. Join Worker Nodes

On each worker node, run the join command that was output by `kubeadm init` on the control plane:

```bash
sudo kubeadm join [CONTROL_PLANE_IP]:6443 --token [TOKEN] --discovery-token-ca-cert-hash [HASH]
```

If you need to regenerate a join token:

```bash
# On control plane node
kubeadm token create --print-join-command
```

## Additional Components

### Install MetalLB for Load Balancing
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml

# Create ConfigMap for MetalLB (adjust IP range to your network)
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.178.90-192.168.178.100
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF
```

### Install NGINX Ingress Controller
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
```

### Install cert-manager for TLS certificates
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
```

## Verification

```bash
# Check node status
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system
```

---

## Migrating Services

After setting up your new cluster, you'll need to migrate your existing services. Consider:

1. Backing up any important configuration and data
2. Recreating your deployments, services, and ingress rules
3. Migrating persistent data if applicable

Your existing YAML files (coredns.yaml, ingress.yaml, etc.) can be reapplied to the new cluster with minimal modification.
