# Bootstrap Guide for Managed Kubernetes Environments

This guide covers bootstrapping a complete GitOps environment on managed Kubernetes clusters (AKS, EKS, GKE).

## Prerequisites

- Access to a managed Kubernetes cluster (AKS, EKS, or GKE)
- `kubectl` configured to access the cluster
- `argocd` CLI installed
- `helm` CLI installed
- Git repository cloned locally

## Architecture Overview

The managed environment differs from bare-metal in key ways:
- **No fixed IPs**: Cloud provider assigns LoadBalancer IPs dynamically
- **Storage**: Uses cloud provider's default storage class (not local-path)
- **No Velero**: Backup solutions depend on cloud provider capabilities
- **Vault addressing**: Uses cluster-internal DNS names

## Bootstrap Process

### Step 1: Install ArgoCD

```bash
# Add ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD without fixed IPs (cloud provider assigns)
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true \
  --wait
```

### Step 2: Get ArgoCD Access

```bash
# Get the ArgoCD server LoadBalancer IP (wait for EXTERNAL-IP)
kubectl get svc argocd-server -n argocd

# Get admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d

# Login to ArgoCD (replace <EXTERNAL-IP> with actual IP)
argocd login <EXTERNAL-IP> --username admin --password <PASSWORD> --insecure
```

### Step 3: Deploy Root Application

```bash
# Apply the root app-of-apps application
kubectl apply -f gitops/clusters/managed/root-app.yaml
```

### Step 4: Initialize Vault

After Vault is deployed by ArgoCD:

```bash
# Wait for Vault pod to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &

# Initialize Vault
export VAULT_ADDR='http://localhost:8200'
vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/vault-init.json

# Unseal Vault
UNSEAL_KEY=$(cat /tmp/vault-init.json | jq -r '.unseal_keys_b64[0]')
vault operator unseal $UNSEAL_KEY

# Get root token
ROOT_TOKEN=$(cat /tmp/vault-init.json | jq -r '.root_token')
```

### Step 5: Configure Vault Secrets

```bash
# Login to Vault
vault login $ROOT_TOKEN

# Enable KV v2 secrets engine
vault secrets enable -version=2 -path=secret kv

# Create required secrets
vault kv put secret/minio/config \
  root_user="minioadmin" \
  root_password="<SECURE_PASSWORD>"

vault kv put secret/homepage/config \
  proxmox_password="" \
  argocd_token="" \
  portainer_key="" \
  grafana_password="admin" \
  synology_password=""

vault kv put secret/synology/config \
  password="<NAS_PASSWORD>"

# Create token for External Secrets Operator
vault token create -policy=default -ttl=87600h -format=json | jq -r '.auth.client_token' > /tmp/vault-token.txt
```

### Step 6: Deploy Vault Token to Namespaces

```bash
# Create vault-token secret in each namespace that needs it
for ns in default homepage minio; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic vault-token \
    --from-literal=token=$(cat /tmp/vault-token.txt) \
    -n $ns
done
```

### Step 7: Sync ArgoCD Applications

```bash
# Sync infrastructure apps first
argocd app sync external-secrets-operator
argocd app sync cert-manager

# Wait for CRDs to be ready
sleep 30

# Sync remaining apps
argocd app sync managed-root --prune
```

## Verification

Check that all applications are healthy:

```bash
# Check ArgoCD applications
argocd app list

# Check pods in all namespaces
kubectl get pods -A

# Check LoadBalancer services
kubectl get svc -A | grep LoadBalancer
```

## Key Differences from Bare-Metal

1. **No MetalLB**: Cloud provider handles LoadBalancer services
2. **Storage Classes**: Use `default` instead of `local-path`
3. **No Fixed IPs**: Services get dynamic external IPs from cloud provider
4. **Vault Access**: Use internal cluster DNS (`vault.vault.svc.cluster.local`)
5. **No NAS Dependencies**: MinIO uses cloud storage, no NFS mounts

## Troubleshooting

### Pods Stuck in Pending
- Check PVC status: `kubectl get pvc -A`
- Ensure using `default` storage class, not `local-path`

### LoadBalancer Services Pending
- Cloud provider may take 2-3 minutes to provision external IPs
- Check cloud provider quotas and permissions

### External Secrets Not Syncing
- Verify Vault is unsealed: `vault status`
- Check vault-token secret exists in namespace
- Verify SecretStore can reach Vault service

### ArgoCD Out of Sync
- Ensure using latest git revision: `argocd app get <app> --refresh`
- Check for git branch mismatches (should use `envs` branch for managed)

## Clean Restart

To completely restart from scratch:

```bash
# Delete all ArgoCD applications
kubectl delete applications -n argocd --all

# Delete the managed-root application
kubectl delete -f gitops/clusters/managed/root-app.yaml

# Optionally, uninstall ArgoCD completely
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Start over from Step 1
```

## Security Notes

- Store Vault init output securely (`/tmp/vault-init.json`)
- Rotate Vault tokens regularly
- Use cloud provider's secret management for production
- Enable Vault auto-unseal using cloud KMS for production