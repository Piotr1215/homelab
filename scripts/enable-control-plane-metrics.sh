#!/bin/bash
set -e

echo "This script will enable metrics for Kubernetes control plane components"
echo "Run this on the control plane node (kube-main / 192.168.178.87)"
echo ""
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# 1. Enable kube-proxy metrics
echo "1. Configuring kube-proxy metrics..."
kubectl -n kube-system get configmap kube-proxy -o yaml | \
  sed 's/metricsBindAddress: ""/metricsBindAddress: 0.0.0.0:10249/' | \
  sed 's/metricsBindAddress: 127.0.0.1:10249/metricsBindAddress: 0.0.0.0:10249/' | \
  kubectl apply -f -

# Restart kube-proxy pods
kubectl -n kube-system rollout restart daemonset kube-proxy

# 2. Enable kube-controller-manager metrics
echo "2. Configuring kube-controller-manager metrics..."
cat <<EOF | sudo tee /tmp/kube-controller-manager-patch.yaml
spec:
  containers:
  - name: kube-controller-manager
    command:
    - kube-controller-manager
    - --bind-address=0.0.0.0
EOF

sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-controller-manager.yaml

# 3. Enable kube-scheduler metrics  
echo "3. Configuring kube-scheduler metrics..."
sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-scheduler.yaml

# 4. Enable etcd metrics
echo "4. Configuring etcd metrics..."
sudo sed -i 's/--listen-metrics-urls=http:\/\/127.0.0.1:2381/--listen-metrics-urls=http:\/\/0.0.0.0:2381/' /etc/kubernetes/manifests/etcd.yaml

echo ""
echo "Configuration complete! The control plane pods will restart automatically."
echo "Wait 2-3 minutes for all components to restart, then check Prometheus targets."
echo ""
echo "To verify locally:"
echo "  curl http://192.168.178.87:10249/metrics  # kube-proxy"
echo "  curl http://192.168.178.87:10257/metrics  # kube-controller-manager"  
echo "  curl http://192.168.178.87:10259/metrics  # kube-scheduler"
echo "  curl http://192.168.178.87:2381/metrics    # etcd"