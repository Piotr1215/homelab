# Secrets Management with Bitwarden & ESO

This guide explains how to set up secrets management for the homelab using Bitwarden Secrets Manager and External Secrets Operator (ESO).

## Overview

- **Secret Store**: Bitwarden Secrets Manager (cloud-based or self-hosted)
- **Sync Mechanism**: External Secrets Operator (ESO)
- **Kubernetes Integration**: Automatic sync of secrets from Bitwarden to Kubernetes

## Prerequisites

1. Bitwarden Secrets Manager account (organization)
2. External Secrets Operator installed in the cluster
3. `direnv` installed for managing local environment variables (optional)

## Local Development Setup

For local development, copy `.envrc.example` to `.envrc` and update with your values:

```bash
cp .envrc.example .envrc
# Edit .envrc with your Bitwarden credentials
direnv allow
```

Required environment variables:
- `BITWARDEN_ORG_ID` - Your Bitwarden organization ID
- `BITWARDEN_PROJECT_ID` - Your Bitwarden project ID
- `BITWARDEN_MACHINE_ACCOUNT_TOKEN` - Machine account token for ESO
- `KUBECONFIG` - Path to your kubeconfig file

For a detailed guide on using direnv for managing environment variables, watch this tutorial:

[![Direnv Tutorial](https://img.youtube.com/vi/uaYJb_oROeo/0.jpg)](https://www.youtube.com/watch?v=uaYJb_oROeo)

## Setup Process

### 1. Set Up Bitwarden Secrets Manager

1. Log in to your Bitwarden account
2. Navigate to your Organization settings
3. Enable Secrets Manager
4. Create a new Project for your homelab secrets
5. Create a Machine Account with access to the project
6. Generate an access token for the machine account

### 2. Configure ESO with Bitwarden Credentials

After bootstrap deployment, configure Bitwarden credentials:

```bash
# Set environment variables
export BITWARDEN_ORG_ID=your-org-id
export BITWARDEN_PROJECT_ID=your-project-id
export BITWARDEN_MACHINE_ACCOUNT_TOKEN=your-token

# Apply Bitwarden credentials to cluster
just patch-bitwarden
```

This creates the necessary Kubernetes secret that ESO uses to authenticate with Bitwarden.

### 3. Create Secrets in Bitwarden

Add your secrets to Bitwarden Secrets Manager under your project:

```
homelab/
├── homepage/
│   ├── proxmox_password
│   ├── argocd_token
│   ├── portainer_key
│   └── grafana_password
├── minio/
│   ├── root_user
│   └── root_password
├── synology/
│   └── password
└── influxdb/
    ├── admin_token
    └── proxmox_token
```

### 4. Apply ESO Configurations

Deploy the SecretStores and ExternalSecrets:

```bash
kubectl apply -f gitops/infra/eso-secretstores.yaml
kubectl apply -f gitops/infra/eso-externalsecrets.yaml
```

### 5. Verify Secrets Creation

Check that ESO has created the Kubernetes secrets:

```bash
# Check Homepage secrets
kubectl get secret homepage-secrets -n homepage
kubectl describe externalsecret homepage-secrets -n homepage

# Check MinIO secrets
kubectl get secret minio-secrets -n minio
kubectl describe externalsecret minio-secrets -n minio

# Check other secrets
kubectl get secret synology-secrets -n default
kubectl get secret influxdb-secrets -n default
```

### 6. Deploy Applications

Now you can deploy the applications that use these secrets via ArgoCD.

## Secret Structure in Bitwarden

Secrets are organized in Bitwarden Secrets Manager under your project with the following naming convention:

- Use forward slashes to organize secrets hierarchically
- Keep secret names lowercase with underscores
- Match the secret keys expected by your applications

## Updating Secrets

To update a secret:

1. Update the value in Bitwarden Secrets Manager
2. ESO will automatically sync the changes (default refresh interval: 1h)

To force immediate sync:

```bash
kubectl annotate externalsecret homepage-secrets -n homepage force-sync=$(date +%s) --overwrite
```

## Troubleshooting

### Check ESO logs

```bash
kubectl logs -n external-secrets deployment/external-secrets
```

### Check Bitwarden connectivity

```bash
# Check if the SecretStore is ready
kubectl get secretstore -A
kubectl describe secretstore bitwarden-secretstore -n external-secrets
```

### Verify Bitwarden credentials

```bash
kubectl get secret bitwarden-credentials -n external-secrets -o jsonpath='{.data.token}' | base64 -d
```

### Check ExternalSecret status

```bash
kubectl describe externalsecret homepage-secrets -n homepage
```

Look for:
- **Condition: Ready = True** - Secret synced successfully
- **Condition: Ready = False** - Check error message for details

### Common Issues

1. **SecretStore not ready**
   - Verify Bitwarden credentials are correct
   - Check network connectivity to Bitwarden API
   - Review ESO logs for authentication errors

2. **ExternalSecret not creating Kubernetes Secret**
   - Verify secret exists in Bitwarden with correct path/name
   - Check that the SecretStore is ready
   - Ensure namespace and RBAC permissions are correct

3. **Secrets not updating**
   - Check refresh interval in ExternalSecret spec
   - Force sync using kubectl annotate command above
   - Verify secret was actually changed in Bitwarden

## Security Notes

- Never commit Bitwarden credentials to the repository
- The machine account token should have minimal required permissions
- Secrets are only accessible within their respective namespaces
- ESO refreshes secrets every hour by default
- Consider using self-hosted Bitwarden Vaultwarden for complete control

## Bitwarden vs Vault

**Why Bitwarden + ESO?**
- ✅ Managed service (no maintenance overhead)
- ✅ Built-in UI for secret management
- ✅ Mobile apps for emergency access
- ✅ Robust backup and disaster recovery
- ✅ Team sharing and access control
- ✅ Self-hosting option available (Vaultwarden)

**When Vault might be better:**
- Need advanced secret engines (PKI, database credentials)
- Require fine-grained dynamic secrets
- On-premise compliance requirements
- Complex secret rotation workflows
