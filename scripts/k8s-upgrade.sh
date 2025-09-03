#!/usr/bin/env bash
# Thin wrapper - follows official kubeadm upgrade process exactly
set -e

TARGET="${1:-v1.33.4}"
V="${TARGET#v}-*"
MINOR=$(echo "$TARGET" | cut -d. -f2)

echo "Upgrading to $TARGET"

# Control plane - following official docs exactly
ssh -o StrictHostKeyChecking=no decoder@192.168.178.87 "
export DEBIAN_FRONTEND=noninteractive
# Update repo for new minor version
sudo sed -i 's|/v1\.[0-9]*/deb/|/v1.$MINOR/deb/|g' /etc/apt/sources.list.d/kubernetes.list
# Upgrade kubeadm first
sudo apt-mark unhold kubeadm
sudo apt update -qq && sudo apt install -yqq kubeadm=$V
sudo apt-mark hold kubeadm
# Apply the upgrade
sudo kubeadm upgrade apply $TARGET --ignore-preflight-errors=CreateJob -y
# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt install -yqq kubelet=$V kubectl=$V
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
"

# Workers - following official docs
for IP in 192.168.178.88 192.168.178.89; do
  echo "Worker $IP"
  # Upgrade kubeadm first
  ssh -o StrictHostKeyChecking=no decoder@$IP "
  export DEBIAN_FRONTEND=noninteractive
  sudo sed -i 's|/v1\.[0-9]*/deb/|/v1.$MINOR/deb/|g' /etc/apt/sources.list.d/kubernetes.list
  sudo apt-mark unhold kubeadm
  sudo apt update -qq && sudo apt install -yqq kubeadm=$V
  sudo apt-mark hold kubeadm
  # Upgrade node config
  sudo kubeadm upgrade node
  # Upgrade kubelet and kubectl
  sudo apt-mark unhold kubelet kubectl
  sudo apt install -yqq kubelet=$V kubectl=$V
  sudo apt-mark hold kubelet kubectl
  sudo systemctl daemon-reload && sudo systemctl restart kubelet
  "
done

kubectl get nodes
kubectl version