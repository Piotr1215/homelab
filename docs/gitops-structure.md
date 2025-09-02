# GitOps Structure Overview

## Current Architecture

### Application Layer (`/gitops/clusters/homelab/`)
- **infrastructure.yaml** - Core platform components (monitoring, storage, scanning)
- **apps.yaml** - User-facing applications 
- **vault.yaml** - Secrets management
- **cert-manager.yaml** - Certificate management
- **external-secrets-operator.yaml** - External secrets sync
- **ingress-nginx.yaml** - Ingress controller

### Infrastructure Resources (`/gitops/infra/`)
- **cluster-scanning.yaml** - Security scanning CronJobs (Popeye, Kubescape)
- **kube-prometheus-stack.yaml** - Monitoring stack (Prometheus + Grafana)
- **loki-stack.yaml** - Log aggregation
- **metallb-ip-pools.yaml** - Load balancer IP management
- **local-path-provisioner.yaml** - Dynamic PV provisioning
- **local-storage-class.yaml** - Storage class definitions
- **eso-*.yaml** - External Secrets configuration
- **cert-manager-issuer.yaml** - Certificate issuers
- **vault-values.yaml** - Vault helm values
- **kube-cleanup-operator.yaml** - Resource cleanup automation

### Application Resources (`/gitops/apps/`)
- **homepage.yaml** - Dashboard application (includes ServiceAccount)
- **homepage-serviceaccount.yaml** - Separate SA definition (DUPLICATE?)
- **minio.yaml** - Object storage deployment
- **minio-*.yaml** - MinIO PV/PVC definitions (could be consolidated)
- **hubble-ui-lb.yaml** - Cilium network observability UI
- **nginx-deployment.yaml** - Test nginx deployment
- **web-app.yaml** - Sample web application

## Issues Found

### Duplications
1. **homepage-serviceaccount.yaml** - Already defined in homepage.yaml
2. **Service definitions** - Were duplicated between apps and infrastructure

### Structural Issues
1. **No ArgoCD Projects** - Everything uses 'default' project (no RBAC separation)
2. **Mixed responsibilities** - Infrastructure app manages some app resources
3. **No clear naming convention** - Mix of helm apps and raw manifests

## Fixed IP Assignments

| Service | IP | Pool |
|---------|-----|------|
| ArgoCD Server | 192.168.178.98 | core-services |
| Homepage | 192.168.178.93 | app-services |
| Prometheus | 192.168.178.90 | core-services |
| Grafana | 192.168.178.96 | app-services |
| Vault UI | 192.168.178.92 | core-services |
| MinIO | 192.168.178.97 | app-services |
| Hubble UI | 192.168.178.94 | app-services |
| Ingress | 192.168.178.99 | app-services |

## Recommended Next Steps

1. **Consolidate MinIO resources** - Merge PV/PVC definitions into minio.yaml
2. **Remove duplicate ServiceAccount** - Delete homepage-serviceaccount.yaml
3. **Create ArgoCD Projects** - Separate infrastructure, platform, and apps
4. **Standardize naming** - Use consistent prefixes (infra-, platform-, app-)
5. **Document recovery process** - Create runbook for cluster restoration