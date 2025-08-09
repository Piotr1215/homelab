# Kubernetes Homelab Cheatsheet

## VM Management (Proxmox)

```bash
# List all VMs
qm list

# Start a VM
qm start <vmid>

# Stop a VM
qm stop <vmid>

# Get VM info
qm config <vmid>

# VM console
qm terminal <vmid>

# Create a clone from template
qm clone <template-vmid> <new-vmid> --name <name> --full
```

## Kubernetes Setup

```bash
# Initialize control plane
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12

# Set up kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Get join command
kubeadm token create --print-join-command

# Join worker nodes
sudo kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash>

# Reset kubeadm (if needed)
sudo kubeadm reset
```

## Kubernetes Basics

```bash
# Get nodes
kubectl get nodes -o wide

# Get all pods
kubectl get pods -A

# Get services
kubectl get services -A

# Get ingress
kubectl get ingress -A

# Get deployments
kubectl get deployments -A

# Describe resource
kubectl describe <resource-type> <resource-name> -n <namespace>

# Get logs
kubectl logs <pod-name> -n <namespace>

# Execute command in pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# Port forwarding
kubectl port-forward <pod-name> <local-port>:<pod-port> -n <namespace>
```

## Helm Commands

```bash
# Add a repository
helm repo add <name> <url>

# Update repositories
helm repo update

# List repositories
helm repo list

# Search for charts
helm search repo <keyword>

# Install a chart
helm install <release-name> <chart-name> -n <namespace> --create-namespace

# List installed releases
helm list -A

# Upgrade a release
helm upgrade <release-name> <chart-name> -n <namespace>

# Uninstall a release
helm uninstall <release-name> -n <namespace>
```

## ConfigMaps and Secrets

```bash
# Create ConfigMap
kubectl create configmap <name> --from-file=<path> -n <namespace>

# Create secret
kubectl create secret generic <name> --from-literal=key=value -n <namespace>

# Create TLS secret
kubectl create secret tls <name> --cert=<cert-path> --key=<key-path> -n <namespace>
```

## Network Troubleshooting

```bash
# Test DNS resolution from within a pod
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -n default --rm -it -- nslookup kubernetes.default

# Test connectivity between pods
kubectl run busybox --image=busybox:1.28 -n default --rm -it -- wget -qO- <service-name>.<namespace>.svc.cluster.local

# Check CNI plugin status
kubectl get pods -n kube-system -l k8s-app=calico-node
```

## RBAC

```bash
# Create service account
kubectl create serviceaccount <name> -n <namespace>

# Create role
kubectl create role <name> --verb=get,list,watch --resource=pods -n <namespace>

# Create role binding
kubectl create rolebinding <name> --role=<role-name> --serviceaccount=<namespace>:<sa-name> -n <namespace>

# Get service account token
kubectl -n <namespace> create token <service-account-name>
```

## Application Deployment

```bash
# Create deployment
kubectl create deployment <name> --image=<image> -n <namespace>

# Scale deployment
kubectl scale deployment <name> --replicas=<count> -n <namespace>

# Expose deployment as service
kubectl expose deployment <name> --port=<port> --target-port=<target-port> --type=ClusterIP -n <namespace>
```

## Custom Resources

```bash
# Get certificate resources
kubectl get certificates -A

# Get certificate issuers
kubectl get clusterissuers

# Get storage classes
kubectl get storageclasses

# Get persistent volume claims
kubectl get pvc -A
```

## Cleanup

```bash
# Delete namespace and everything in it
kubectl delete namespace <namespace>

# Delete all resources in a namespace
kubectl delete all --all -n <namespace>

# Drain a node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```