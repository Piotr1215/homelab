#!/usr/bin/env bash
# Thin wrapper - just SSH and run kubeadm
set -e

TARGET="${1:-v1.33.4}"
V="${TARGET#v}-*"
MINOR=$(echo "$TARGET" | cut -d. -f2)

echo "Upgrading to $TARGET"

# Control plane
ssh -o StrictHostKeyChecking=no decoder@192.168.178.87 "
export DEBIAN_FRONTEND=noninteractive
sudo sed -i 's|/v1\.[0-9]*/deb/|/v1.$MINOR/deb/|g' /etc/apt/sources.list.d/kubernetes.list
sudo apt update -qq && sudo apt install -yqq kubeadm=$V
sudo kubeadm upgrade apply $TARGET -y
sudo apt install -yqq kubelet=$V kubectl=$V
sudo systemctl daemon-reload && sudo systemctl restart kubelet
"

# Workers
for IP in 192.168.178.88 192.168.178.89; do
  echo "Worker $IP"
  ssh -o StrictHostKeyChecking=no decoder@$IP "
  export DEBIAN_FRONTEND=noninteractive
  sudo sed -i 's|/v1\.[0-9]*/deb/|/v1.$MINOR/deb/|g' /etc/apt/sources.list.d/kubernetes.list
  sudo apt update -qq && sudo apt install -yqq kubeadm=$V
  sudo kubeadm upgrade node
  sudo apt install -yqq kubelet=$V kubectl=$V
  sudo systemctl daemon-reload && sudo systemctl restart kubelet
  "
done

kubectl get nodes