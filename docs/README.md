# Homelab GitOps Repository

## Video Tutorial

[![Homelab GitOps Setup](https://img.youtube.com/vi/5YFmYcic8XQ/0.jpg)](https://www.youtube.com/watch?v=5YFmYcic8XQ)

> Watch the complete homelab setup walkthrough on YouTube.

GitOps Kubernetes cluster with ArgoCD and External Secrets Operator (ESO) using Bitwarden Secrets Manager. Bootstrap installs core services, ArgoCD handles everything else.

## Repository Pattern

This repo follows a 2-layer ApplicationSet pattern. K8s manifests and Helm values live in `gitops/apps/`. ApplicationSets in `gitops/appsets/` generate ArgoCD Applications from those manifests. A single `appsets-loader` bootstraps everything. No Helm values are inlined in ArgoCD resources - all config stays in Git.

```
gitops/
  apps/        <- K8s manifests + values.yaml per app
  appsets/     <- ApplicationSets (apps-helm, apps-raw)
  clusters/    <- appsets-loader bootstrap
```

## Setup

Clone the repository and ensure you have access to your Kubernetes cluster.

```bash
git clone https://github.com/decodersam/homelab && cd homelab
# Ensure kubeconfig is available (either in ~/.kube/config or ./kubeconfig)
export KUBECONFIG=./kubeconfig  # if using local kubeconfig
```

## Bootstrap

Deploy the core infrastructure components using Terraform. This sets up ArgoCD and essential operators.

### Fresh install

```bash
terraform init && terraform apply
```

### Required files
- `kubeconfig` - Required
- Bitwarden Secrets Manager credentials (configured after bootstrap)

## Access

Service endpoints are available via LoadBalancer IPs. Use these commands to get the URLs:

```bash
# Get ArgoCD URL
kubectl get svc -n argocd argocd-server -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}'

# Get Homepage URL
kubectl get svc -n homepage homepage -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}'
```

## Operations

Common commands for managing and monitoring your GitOps deployment.

```bash
just --list              # Show all commands
just launch_argo         # Open ArgoCD UI
kubectl get app -n argocd  # Check app status
```

## Image Updates

ArgoCD Image Updater automatically tracks and updates container images using semantic versioning.

**Requirements:**
- Application must use **Kustomize** or **Helm** source type (not Directory)
- Current image tag must be semver-compliant (e.g., `1.0.0`, not `latest`)
- Tags must match the configured regex pattern

**Example annotations:**
```yaml
argocd-image-updater.argoproj.io/image-list: myapp=docker.io/user/image
argocd-image-updater.argoproj.io/myapp.update-strategy: semver
argocd-image-updater.argoproj.io/myapp.allow-tags: regexp:^[0-9]+\.[0-9]+\.[0-9]+$
argocd-image-updater.argoproj.io/write-back-method: git
argocd-image-updater.argoproj.io/git-branch: main
```

## Secrets

External Secrets Operator with [Bitwarden](https://external-secrets.io/latest/provider/bitwarden-secrets-manager/) provider.

### Bitwarden setup
After deployment, configure [Bitwarden Secrets Manager](https://bitwarden.com/help/secrets-manager-overview/) credentials from environment:
```bash
export BITWARDEN_ORG_ID=your-org-id
export BITWARDEN_PROJECT_ID=your-project-id
export BITWARDEN_MACHINE_ACCOUNT_TOKEN=your-token
just patch-bitwarden
```

## Troubleshooting

Quick fixes for common issues you might encounter.

- Jobs disappear quickly: kube-cleanup-operator deletes after 15min
- ESO not syncing: Check Bitwarden credentials and secret paths in ExternalSecrets
