#!/usr/bin/env bash
# Join a new Kubernetes worker node to the cluster
# Follows official Kubernetes documentation:
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes
#
# Prerequisites:
# - Worker node has kubeadm, kubelet, and container runtime installed
# - Worker IP is NOT in MetalLB pool ranges (see docs/IP_ALLOCATION.md)
#
# Usage: ./__join-worker.sh <worker-ip>
#
# NOTE: Consider kubespray for production: https://github.com/kubernetes-sigs/kubespray

set -eo pipefail

CONTROL_PLANE="192.168.178.87"
WORKER_IP="${1:?Usage: $0 <worker-ip>}"

# Generate join command with fresh token (recommended by K8s docs)
# Uses: sudo kubeadm token create --print-join-command
echo "Generating join token on control plane..."
JOIN_CMD=$(ssh -o StrictHostKeyChecking=no decoder@"$CONTROL_PLANE" \
    'sudo kubeadm token create --print-join-command')

# Execute join command on worker node
# This runs: kubeadm join --token <token> <control-plane>:6443 --discovery-token-ca-cert-hash sha256:<hash>
echo "Joining worker $WORKER_IP to cluster..."
ssh -o StrictHostKeyChecking=no decoder@"$WORKER_IP" "sudo $JOIN_CMD"

echo ""
echo "Waiting for node to register (may take 30-60 seconds)..."
sleep 30
kubectl get nodes

echo ""
echo "Join complete! Run 'kubectl get nodes' to verify node is Ready."
