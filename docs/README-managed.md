# Managed Kubernetes Setup

## Quick Start

```bash
# 1. Install ArgoCD
kubectl apply -k gitops/clusters/managed/

# 2. Get ArgoCD password & apply root app
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl apply -f gitops/clusters/managed/root-app.yaml

# 3. Initialize Vault (one-time)
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1
# Save the output, unseal with the key, then configure secrets
```

That's it. ArgoCD handles everything else.

## Key Differences from Bare-Metal

- **Storage**: Uses `default` storage class (not `local-path`)
- **IPs**: No hardcoded LoadBalancer IPs - cloud provider assigns them
- **Service Discovery**: CronJob updates ConfigMap with discovered IPs every 2 minutes
- **No bare-metal services**: Removed Proxmox, Portainer, NAS integrations

## Folder Structure

```
gitops/
├── bare-metal/     # Home cluster configs (192.168.x.x IPs, local-path storage)
└── managed/        # Cloud K8s configs (dynamic IPs, default storage)
```

## Troubleshooting

**App stuck deleting?**
```bash
kubectl patch application <app> -n argocd -p '{"metadata":{"finalizers":null}}'
```

**StatefulSet wrong storage?**
Delete the StatefulSet and PVC, ArgoCD will recreate with correct settings.

**Service IPs not updating?**
Check the service-discovery CronJob: `kubectl logs -n homepage -l job-name=service-discovery`