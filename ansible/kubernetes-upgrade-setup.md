# Kubernetes Upgrade Automation Setup

## Quick Upgrade Script (What we just did manually)

For quick upgrades without Kubespray, here's what we did today automated:

```bash
#!/bin/bash
# File: quick-k8s-upgrade.sh

NEW_VERSION="1.31.12-1.1"  # Change this to target version
K8S_MINOR="1.31"           # Change this to target minor version

NODES=(
  "192.168.178.87"  # kube-main (control plane)
  "192.168.178.88"  # kube-worker1
  "192.168.178.89"  # kube-worker2
)

# Add new repo to all nodes
for node in "${NODES[@]}"; do
  echo "Adding K8s v${K8S_MINOR} repo to $node..."
  ssh -o StrictHostKeyChecking=no decoder@$node "
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-v${K8S_MINOR}-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-v${K8S_MINOR}-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes-v${K8S_MINOR}.list
    sudo apt update
  "
done

# Upgrade control plane
echo "Upgrading control plane..."
kubectl drain kube-main --ignore-daemonsets --delete-emptydir-data
ssh -o StrictHostKeyChecking=no decoder@192.168.178.87 "
  sudo apt-mark unhold kubeadm
  sudo apt-get install -y kubeadm=${NEW_VERSION}
  sudo apt-mark hold kubeadm
  sudo kubeadm upgrade apply v${K8S_MINOR}.12 --ignore-preflight-errors=all -y
  sudo apt-mark unhold kubelet kubectl
  sudo apt-get install -y kubelet=${NEW_VERSION} kubectl=${NEW_VERSION}
  sudo apt-mark hold kubelet kubectl
  sudo systemctl daemon-reload
  sudo systemctl restart kubelet
"
kubectl uncordon kube-main

# Upgrade workers
for i in 1 2; do
  NODE="kube-worker${i}"
  IP="${NODES[$i]}"
  echo "Upgrading $NODE..."
  
  kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force --disable-eviction
  
  ssh -o StrictHostKeyChecking=no decoder@$IP "
    sudo apt-mark unhold kubeadm
    sudo apt-get install -y kubeadm=${NEW_VERSION}
    sudo apt-mark hold kubeadm
    sudo kubeadm upgrade node
    sudo apt-mark unhold kubelet kubectl
    sudo apt-get install -y kubelet=${NEW_VERSION} kubectl=${NEW_VERSION}
    sudo apt-mark hold kubelet kubectl
    sudo systemctl daemon-reload
    sudo systemctl restart kubelet
  "
  
  kubectl uncordon $NODE
done

# Post-upgrade tasks
echo "Unsealing Vault..."
kubectl exec -n vault vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Checking cluster status..."
kubectl get nodes
```

## Kubespray Setup (Recommended for future)

### 1. Clone Kubespray

```bash
cd /home/decoder/dev/homelab
git clone https://github.com/kubernetes-sigs/kubespray
cd kubespray
```

### 2. Install requirements

```bash
pip3 install -r requirements.txt
```

### 3. Create inventory for your cluster

```bash
cp -rfp inventory/sample inventory/homelab
```

### 4. Update inventory file

Create `inventory/homelab/hosts.yaml`:

```yaml
all:
  hosts:
    kube-main:
      ansible_host: 192.168.178.87
      ip: 192.168.178.87
      access_ip: 192.168.178.87
    kube-worker1:
      ansible_host: 192.168.178.88
      ip: 192.168.178.88
      access_ip: 192.168.178.88
    kube-worker2:
      ansible_host: 192.168.178.89
      ip: 192.168.178.89
      access_ip: 192.168.178.89
  children:
    kube_control_plane:
      hosts:
        kube-main:
    kube_node:
      hosts:
        kube-worker1:
        kube-worker2:
    etcd:
      hosts:
        kube-main:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```

### 5. Configure for your environment

Edit `inventory/homelab/group_vars/all/all.yml`:

```yaml
ansible_user: decoder
ansible_become: yes
ansible_become_method: sudo

# Use existing container runtime
container_manager: containerd

# Match your current network plugin (you use Cilium)
kube_network_plugin: cilium

# Version to upgrade to
kube_version: v1.31.12
```

### 6. Run upgrade

```bash
# Test connectivity first
ansible all -i inventory/homelab/hosts.yaml -m ping

# Run the upgrade
ansible-playbook -i inventory/homelab/hosts.yaml upgrade-cluster.yml \
  -e kube_version=v1.31.12 \
  -b -v
```

## Important Notes

1. **Always backup first**: `just backup-velero "before k8s upgrade"`
2. **Unseal Vault after upgrade**: The vault will be sealed after node restarts
3. **Check for PodDisruptionBudget issues**: Some pods like `loft` may need force drain
4. **Monitor services after upgrade**: 
   - Loki/Promtail may need RBAC fixes
   - Grafana may have PVC permission issues
   - External-secrets needs Vault unsealed

## Grafana Permission Fix (if needed)

If Grafana has init container permission issues after upgrade:

```bash
# Scale down
kubectl scale deployment -n prometheus kube-prometheus-stack-grafana --replicas=0

# Fix permissions on the node hosting the PVC
# Find the node and path:
kubectl get pv $(kubectl get pvc -n prometheus kube-prometheus-stack-grafana -o jsonpath='{.spec.volumeName}') -o yaml | grep path

# SSH to that node and fix permissions:
ssh decoder@<node-ip> "sudo chown -R 472:472 /path/to/pvc"

# Scale back up
kubectl scale deployment -n prometheus kube-prometheus-stack-grafana --replicas=1
```