# Managed Kubernetes (AKS) Bootstrap Guide

## Overview
This guide documents the process of bootstrapping a clean managed Kubernetes environment (tested on AKS) with GitOps using ArgoCD.

## Prerequisites
- Access to a managed Kubernetes cluster (AKS, EKS, GKE)
- `kubectl` configured to access the cluster
- `argocd` CLI installed
- Git repository with GitOps manifests

## Bootstrap Process

### Step 1: Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for ArgoCD to be ready:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### Step 2: Access ArgoCD
Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Port-forward to access UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Login with CLI:
```bash
argocd login localhost:8080 --username admin --password <password> --insecure
```

### Step 3: Apply Root Application
```bash
kubectl apply -f gitops/clusters/managed/root-app.yaml
```

This creates the app-of-apps pattern that manages all other applications.

### Step 4: Initialize and Unseal Vault

Apply Vault manually first (it needs to be initialized before ESO can use it):
```bash
kubectl apply -f gitops/managed/vault-app.yaml
```

Wait for Vault pod to be running:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
```

Initialize Vault:
```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json
```

Unseal Vault:
```bash
UNSEAL_KEY=$(cat vault-keys.json | jq -r ".unseal_keys_b64[]")
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

### Step 5: Configure Vault for ESO

Port-forward to Vault:
```bash
kubectl port-forward -n vault svc/vault 8200:8200 &
```

Login to Vault:
```bash
export VAULT_ADDR='http://127.0.0.1:8200'
ROOT_TOKEN=$(cat vault-keys.json | jq -r ".root_token")
vault login $ROOT_TOKEN
```

Enable KV secrets engine:
```bash
vault secrets enable -path=secret kv-v2
```

Create required secrets:
```bash
# Homepage secrets
vault kv put secret/homepage/config \
  argocd_token="<generate-argocd-token>" \
  grafana_password="prom-operator"
```

Create vault-token secret for ESO in all namespaces:
```bash
for ns in homepage vault external-secrets grafana velero; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic vault-token \
    --from-literal=token=$ROOT_TOKEN \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
```

### Step 6: Fix Storage Issues

For StatefulSets using wrong storage class, you need to:

1. Delete the StatefulSet (keeping pods):
```bash
kubectl delete statefulset <name> -n <namespace> --cascade=orphan
```

2. Delete the PVC with wrong storage class:
```bash
kubectl delete pvc <pvc-name> -n <namespace>
```

3. Create new PVC with correct storage class:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: <size>
  storageClassName: default  # Use 'default' for AKS
EOF
```

4. Force sync the application:
```bash
argocd app sync <app-name> --force
```

## Known Issues and Workarounds

### Issue 1: Hardcoded LoadBalancer IPs
**Problem**: Manifests contain hardcoded IPs from bare-metal environment (192.168.x.x)

**Solution**: Remove all `loadBalancerIP` fields from Service definitions in managed environment manifests. Let the cloud provider assign IPs dynamically.

### Issue 2: Wrong Storage Class
**Problem**: Applications use `local-path` storage class which doesn't exist in AKS

**Solution**: 
- For new deployments: Update manifests to use `storageClassName: default`
- For existing StatefulSets: See "Fix Storage Issues" section above

### Issue 3: StatefulSet Immutable Fields
**Problem**: Cannot update storage class on existing StatefulSets

**Solution**: Must delete and recreate the StatefulSet. Follow the procedure in "Fix Storage Issues".

### Issue 4: External Secrets Not Syncing
**Problem**: ESO cannot authenticate with Vault

**Solution**: 
1. Ensure vault-token secret exists in the namespace
2. Restart ESO deployment: `kubectl rollout restart deployment -n external-secrets`

### Issue 5: Homepage Environment Variables
**Problem**: Homepage expects secrets that don't exist in managed environment

**Solution**: Remove references to:
- Proxmox credentials
- Portainer tokens
- Synology/NAS passwords
- Any bare-metal specific services

### Issue 6: ArgoCD Application Stuck Deleting
**Problem**: Application has finalizer preventing deletion

**Solution**:
```bash
kubectl patch application <app-name> -n argocd \
  -p '{"metadata":{"finalizers":null}}' --type merge
```

## Service Discovery

In managed Kubernetes, use cluster-internal DNS for service discovery:
- Pattern: `<service-name>.<namespace>.svc.cluster.local`
- Example: `http://vault.vault.svc.cluster.local:8200`

For Homepage dashboard, update service URLs to use either:
1. Internal cluster URLs (for backend access)
2. LoadBalancer external IPs (for user-facing links)

## Verification

Check all services are running:
```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Check LoadBalancer services got IPs:
```bash
kubectl get svc -A | grep LoadBalancer
```

Check ArgoCD applications are synced:
```bash
argocd app list
```

## Clean Bootstrap Checklist

- [ ] Install ArgoCD
- [ ] Apply root application
- [ ] Initialize and unseal Vault
- [ ] Configure Vault secrets
- [ ] Create vault-token secrets
- [ ] Fix storage class issues
- [ ] Remove hardcoded IPs
- [ ] Update service URLs
- [ ] Verify all pods running
- [ ] Verify services accessible

## Automation Opportunities

1. **Dynamic LoadBalancer IPs**: Create a controller or script to automatically update Homepage with assigned LoadBalancer IPs
2. **Vault Auto-Unseal**: Configure auto-unseal using Azure Key Vault
3. **Storage Class Detection**: Use Helm values or Kustomize to set correct storage class per environment
4. **Environment Separation**: Use different branches or folders for managed vs bare-metal configurations