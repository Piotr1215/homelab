# Secrets Management Setup

This guide explains how to set up secrets management for the homelab using Vault and External Secrets Operator (ESO).

## Prerequisites

1. Vault is installed and running at `http://192.168.178.92:8200`
2. External Secrets Operator is installed in the cluster
3. You have `direnv` installed for managing environment variables

## Setup Process

### 1. Prepare Environment Variables

Copy the template and fill in your actual secrets:

```bash
cp .envrc.template .envrc
# Edit .envrc with your actual secrets
direnv allow
```

### 2. Populate Vault with Secrets

Run the setup script to push all secrets to Vault:

```bash
./scripts/setup-vault-secrets.sh
```

This will:
- Enable KV v2 secrets engine at path `homelab/`
- Store Homepage secrets (Proxmox, ArgoCD, Portainer, Grafana)
- Store MinIO credentials
- Store Synology NAS password
- Store InfluxDB tokens

### 3. Create Vault Token for ESO

Generate and distribute Vault tokens for ESO to use:

```bash
./scripts/create-eso-vault-token.sh
```

This will:
- Create a Vault policy for ESO with read access to `homelab/*`
- Generate a Vault token with that policy
- Create `vault-token` secrets in namespaces: homepage, minio, default

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

Now you can deploy the applications that use these secrets:

```bash
# Deploy Homepage with ESO-managed secrets
kubectl apply -f apps/homepage-with-eso.yaml

# Deploy MinIO with ESO-managed secrets
kubectl apply -f apps/minio-clean.yaml
```

## Secret Structure in Vault

Secrets are organized in Vault under the `homelab/` path:

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

## Updating Secrets

To update a secret:

1. Update the value in `.envrc`
2. Run `direnv allow` to reload environment
3. Run `./scripts/setup-vault-secrets.sh` to update Vault
4. ESO will automatically sync the changes (default refresh interval: 1h)

To force immediate sync:

```bash
kubectl annotate externalsecret homepage-secrets -n homepage force-sync=$(date +%s) --overwrite
```

## Troubleshooting

### Check ESO logs

```bash
kubectl logs -n external-secrets deployment/external-secrets
```

### Check Vault connectivity

```bash
vault status
vault kv list homelab/
vault kv get homelab/homepage
```

### Verify Vault token

```bash
kubectl get secret vault-token -n homepage -o jsonpath='{.data.token}' | base64 -d
```

### Check ExternalSecret status

```bash
kubectl describe externalsecret homepage-secrets -n homepage
```

## Security Notes

- Never commit `.envrc` to the repository
- The Vault token for ESO has read-only access
- Secrets are only accessible within their respective namespaces
- ESO refreshes secrets every hour by default