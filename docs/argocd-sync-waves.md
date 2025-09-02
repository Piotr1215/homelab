# ArgoCD Sync Waves Configuration

## Critical Deployment Order

To ensure proper cluster recovery, applications must be deployed in the correct order using ArgoCD sync waves.

## Sync Wave Order

### Wave -3: Core Storage & Networking
- **local-path-provisioner** - Storage provisioning
- **MetalLB** - LoadBalancer IP allocation
- **Calico/Cilium** - CNI networking

### Wave -2: Certificate Management & Ingress
- **cert-manager** - Certificate management
- **nginx-ingress** (if used)

### Wave -1: Secret Management Infrastructure
- **Vault** - Secret storage (CRITICAL - contains all secrets!)
  - Must preserve PV/PVC
  - Requires unseal on startup
- **External Secrets Operator** - Secret synchronization
  - CRDs must be installed first

### Wave 0: Core Applications
- **External Secret Stores** - Connect ESO to Vault
- **External Secrets** - Pull secrets from Vault
- **Prometheus/Grafana** - Monitoring

### Wave 1: Business Applications
- **Homepage**
- **MinIO**
- **Other apps that depend on secrets**

## Implementation

Add sync-wave annotations to each Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  # ... rest of config
```

## Critical Notes

1. **Vault MUST be backed up regularly** - Contains ALL cluster secrets
2. **ESO SecretStores must use cluster DNS** not IPs: `vault.vault.svc.cluster.local`
3. **MetalLB must be configured before LoadBalancer services**
4. **Storage provisioner must exist before any PVC creation**

## Recovery Process

1. Deploy ArgoCD
2. Apply app-of-apps with sync waves
3. Wait for Wave -3 to complete (storage/networking)
4. Wait for Wave -2 to complete (cert-manager)
5. Wait for Wave -1 to complete (Vault/ESO)
6. Unseal Vault with stored key
7. Verify SecretStores are Valid
8. Continue with remaining waves

## Vault Backup Locations

- Local: `/home/decoder/dev/homelab/backups/vault/`
- NAS: `/home/decoder/mnt/nas-velero/vault-backups/`
- Node: Check all nodes at `/opt/local-path-provisioner/*vault*`