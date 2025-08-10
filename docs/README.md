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
├── terraform/               # Terraform configurations for ArgoCD
│   └── argocd/             # ArgoCD Helm deployment
└── gitops/
    └── infra/              # Infrastructure components (ESO, MetalLB, etc.)
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
cd /home/decoder/dev/homelab/terraform/argocd
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
kubectl apply -f gitops/clusters/homelab/
```

## Video Tutorial

[![Homelab GitOps Setup](https://img.youtube.com/vi/5YFmYcic8XQ/0.jpg)](https://www.youtube.com/watch?v=5YFmYcic8XQ)

Watch the complete homelab setup walkthrough on YouTube.