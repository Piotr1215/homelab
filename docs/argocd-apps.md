# ArgoCD Applications Structure

## Master App-of-Apps
- **app-of-apps** - Manages all other ArgoCD applications

## Infrastructure (Wave -3 to -1)
### Wave -3: Core Storage & Networking
- **metallb** - Load balancer for bare metal (Helm)
- **local-path-provisioner** - Storage provisioner (via infrastructure app)

### Wave -2: Certificate Management
- **cert-manager** - TLS certificate management (Helm)

### Wave -1: Secret Management
- **vault** - HashiCorp Vault for secrets (Helm)
- **external-secrets-operator** - ESO for secret synchronization (Helm)

### Wave 0: Configuration & Monitoring
- **external-secrets-config** - ESO SecretStores and ExternalSecrets
- **kube-prometheus-stack** - Prometheus & Grafana (Helm)
- **loki-stack** - Log aggregation (Helm)
- **infrastructure** - Raw infrastructure manifests (non-Application resources)

## Applications (Wave 1+)
- **apps** - All user applications
  - Homepage dashboard
  - MinIO object storage
  - Hubble UI
  - Various web apps

## AI/ML
- **kagent-crds** - Kagent Custom Resource Definitions
- **kagent** - Kagent AI platform

## Recovery Process
1. Install ArgoCD
2. Apply app-of-apps: `kubectl apply -f gitops/clusters/homelab/app-of-apps.yaml`
3. Push changes to Git
4. ArgoCD will sync and recreate entire cluster state
5. Run vault recovery script if needed: `./scripts/vault-recovery.sh`

## Key Features
- All infrastructure is GitOps managed
- Proper sync waves ensure dependency order
- Automated sync and self-healing enabled
- Vault data is backed up separately (see scripts/vault-backup.sh)