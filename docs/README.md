# Homelab GitOps Repository

## Directory Structure

```
gitops/
├── apps/                     # Application deployments
│   └── */                    # Individual applications
├── clusters/
│   └── homelab/             # Cluster-specific configurations
│       ├── apps.yaml        # App of Apps for applications
│       └── infrastructure.yaml # App of Apps for infrastructure
└── infrastructure/
    ├── core/                # Core infrastructure (ESO, Vault, etc.)
    └── configs/             # Configuration resources (SecretStores, ExternalSecrets)
```

## Deployment Strategy

1. **App of Apps Pattern**: Root applications in `clusters/homelab/` that deploy everything else
2. **Separation of Concerns**: 
   - Infrastructure (operators, controllers)
   - Configs (CRDs, custom resources)
   - Apps (actual applications)

## Getting Started

1. Install ArgoCD:
```bash
cd /home/decoder/dev/homelab/argocd
terraform init
terraform apply
```

2. Get admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

3. Access ArgoCD UI at LoadBalancer IP on port 80

4. Apply root app:
```bash
kubectl apply -f clusters/homelab/
```