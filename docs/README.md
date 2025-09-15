# Homelab GitOps Repository

## Video Tutorial

[![Homelab GitOps Setup](https://img.youtube.com/vi/5YFmYcic8XQ/0.jpg)](https://www.youtube.com/watch?v=5YFmYcic8XQ)

> Watch the complete homelab setup walkthrough on YouTube.

GitOps Kubernetes cluster with ArgoCD and Vault. Bootstrap installs core services, ArgoCD handles everything else.

## Setup

Clone the repository and ensure you have access to your Kubernetes cluster.

```bash
git clone https://github.com/decodersam/homelab && cd homelab
# Ensure kubeconfig is available (either in ~/.kube/config or ./kubeconfig)
export KUBECONFIG=./kubeconfig  # if using local kubeconfig
```

## Bootstrap

Deploy the core infrastructure components using Terraform. This sets up ArgoCD, Vault, and essential operators.

### Fresh install
Creates a new Vault instance with fresh credentials. Secrets will need to be manually populated after deployment.

```bash
terraform init && terraform apply
```

### Restore from backup
Restores from an existing Vault backup if the cluster was previously running and you have a backup snapshot.

```bash
terraform apply -var="vault_snapshot_path=./backup.snap" -var="vault_credentials_path=./vault-init.json"
```

### Required files
- `kubeconfig` - Required
- `vault-backup.snap` - Optional, for restore
- `vault-init.json` - Optional, previous Vault credentials

## Access

Service endpoints and credentials for accessing the deployed components.

- ArgoCD: http://192.168.178.90
- Vault: http://192.168.178.92:8200
- Homepage: http://192.168.178.91
- Credentials: `vault-init.json` (created on fresh install)

## Operations

Common commands for managing and monitoring your GitOps deployment.

```bash
just --list              # Show all commands
just launch_argo         # Open ArgoCD UI
kubectl get app -n argocd  # Check app status
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
- Vault sealed: `kubectl -n vault exec vault-0 -- vault status`
- ESO not syncing: Check vault paths and token validity
