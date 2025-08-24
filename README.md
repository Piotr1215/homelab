# Homelab Kubernetes GitOps

Kubernetes cluster managed with GitOps principles using ArgoCD.

## Supported Environments

This repository supports two deployment environments:

### Bare-Metal Environment (`gitops/bare-metal/`)
- Home cluster with fixed IPs (192.168.x.x range)
- Uses `local-path` storage class
- Includes Proxmox, Portainer, NAS integrations
- MetalLB with predefined IP pools

### Managed Kubernetes (`gitops/managed/`)
- Cloud Kubernetes (AKS, EKS, GKE)
- Dynamic LoadBalancer IPs assigned by cloud provider
- Uses `default` storage class
- Automatic service discovery via CronJob
- Clean, cloud-native setup

## Quick Start

### Managed Kubernetes

```bash
# 1. Install ArgoCD
kubectl apply -k gitops/clusters/managed/

# 2. Get ArgoCD password & apply root app
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl apply -f gitops/clusters/managed/root-app.yaml

# 3. Initialize Vault (one-time)
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1
# Save output, unseal, configure secrets
```

That's it. ArgoCD handles everything else. Service IPs are discovered automatically.

### Bare-Metal

```bash
# Similar to managed, but use bare-metal folder
kubectl apply -f gitops/clusters/bare-metal/root-app.yaml
```

## Key Differences

| Feature | Bare-Metal | Managed |
|---------|------------|---------|
| Storage Class | `local-path` | `default` |
| LoadBalancer IPs | Fixed (192.168.x.x) | Dynamic (cloud-assigned) |
| Service Discovery | Hardcoded | Auto-discovery CronJob |
| Extra Services | Proxmox, NAS, Portainer | None |

## Repository Structure

```
gitops/
├── apps/           # Shared application definitions
├── infra/          # Shared infrastructure components
├── bare-metal/     # Bare-metal specific configs
├── managed/        # Managed K8s specific configs
└── clusters/       # Bootstrap configurations
    ├── bare-metal/
    └── managed/
```

## Common Operations

### Access Services
```bash
# Get all LoadBalancer IPs
kubectl get svc -A | grep LoadBalancer

# Port-forward for local access
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

### Troubleshooting

**App stuck deleting?**
```bash
kubectl patch application <app> -n argocd -p '{"metadata":{"finalizers":null}}'
```

**Wrong storage class on StatefulSet?**
Delete the StatefulSet and PVC, let ArgoCD recreate with correct settings.

## Technologies

- **GitOps**: ArgoCD (app-of-apps pattern)
- **Secrets**: HashiCorp Vault + External Secrets Operator
- **Monitoring**: Prometheus + Grafana + Loki
- **Dashboard**: Homepage with auto-discovery
- **Storage**: MinIO for object storage
- **LoadBalancer**: MetalLB (bare-metal) / Cloud LB (managed)