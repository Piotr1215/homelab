# ESO + Vault Experimentation Setup

## Step 1: Initialize and Apply Terraform

```bash
cd /home/decoder/dev/homelab/eso
terraform init
terraform plan
terraform apply
```

This will:
- Create `vault` and `external-secrets` namespaces
- Install HashiCorp Vault in dev mode (with UI)
- Install External Secrets Operator

## Step 2: Check Deployments

```bash
kubectl get pods -n vault
kubectl get pods -n external-secrets
kubectl get svc -n vault
```

## Step 3: Configure Vault

```bash
./setup-vault.sh
```

This script will:
- Wait for Vault to be ready
- Set up port-forwarding
- Enable KV v2 secrets engine
- Create test secrets
- Configure authentication for ESO
- Create a token for ESO

## Step 4: Deploy SecretStore

```bash
kubectl apply -f secretstore.yaml
kubectl get secretstore -n default
```

## Step 5: Deploy ExternalSecret

```bash
kubectl apply -f externalsecret.yaml
kubectl get externalsecret -n default
```

## Step 6: Verify Secret Creation

```bash
kubectl get secret test-app-credentials -n default
kubectl describe secret test-app-credentials -n default
```

## Vault Access

After running setup-vault.sh, you'll get:
- Vault UI URL: http://127.0.0.1:8200
- Root Token: (displayed in script output)

## Notes

- Vault is running in dev mode (not for production)
- Secrets are stored at `secret/` path in Vault
- ESO polls Vault every 30 seconds by default