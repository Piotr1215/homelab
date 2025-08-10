#!/bin/bash

# Setup Vault secrets for homelab
# This script reads secrets from .envrc and populates them in Vault

set -e

# Check if environment variables are set (they should be loaded by direnv)
if [ -z "$HOMEPAGE_VAR_PROXMOX_PASSWORD" ]; then
    echo "Error: Environment variables not loaded."
    echo "Please ensure direnv is installed and run: direnv allow"
    echo ""
    echo "Alternatively, you can manually export the variables from .envrc:"
    echo "  export VAULT_ADDR='http://127.0.0.1:8200'"
    echo "  export VAULT_TOKEN='root'"
    echo "  # ... and other variables"
    exit 1
fi

# Setup port-forward to Vault
echo "Setting up port-forward to Vault..."
kubectl port-forward -n vault svc/vault 8200:8200 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Use localhost for Vault
export VAULT_ADDR='http://127.0.0.1:8200'

# Check if Vault is accessible
if ! vault status > /dev/null 2>&1; then
    echo "Error: Cannot connect to Vault at $VAULT_ADDR"
    echo "Make sure Vault is running"
    kill $PF_PID 2>/dev/null
    exit 1
fi

# Cleanup function
cleanup() {
    echo "Cleaning up port-forward..."
    kill $PF_PID 2>/dev/null
}
trap cleanup EXIT

echo "Connected to Vault at: $VAULT_ADDR"

# KV v2 secrets engine should already be enabled at 'secret' path by setup-vault.sh
echo "Using existing KV v2 secrets engine at path 'secret'..."

# Store Homepage secrets in Vault
echo "Storing Homepage secrets in Vault..."
vault kv put secret/homepage/config \
  proxmox_password="${HOMEPAGE_VAR_PROXMOX_PASSWORD}" \
  argocd_token="${HOMEPAGE_VAR_ARGOCD_TOKEN}" \
  portainer_key="${HOMEPAGE_VAR_PORTAINER_KEY}" \
  grafana_password="${HOMEPAGE_VAR_GRAFANA_PASSWORD}"

# Store MinIO secrets in Vault
echo "Storing MinIO secrets in Vault..."
vault kv put secret/***REMOVED***/config \
  root_user="${MINIO_ROOT_USER}" \
  root_password="${MINIO_ROOT_PASSWORD}"

# Store Synology NAS secrets in Vault
echo "Storing Synology NAS secrets in Vault..."
vault kv put secret/synology/config \
  password="${SYNOLOGY_PASSWORD}"

# Store InfluxDB secrets in Vault
echo "Storing InfluxDB secrets in Vault..."
vault kv put secret/influxdb/config \
  admin_token="${INFLUX_DB_ADMIN_TOKEN}" \
  proxmox_token="${INFLUX_DB_PROXMOX_TOKEN}"

echo ""
echo "✅ Vault secrets setup complete!"
echo ""
echo "Next steps:"
echo "1. Ensure ESO is installed: kubectl apply -f infrastructure/eso/"
echo "2. Create Vault token for ESO: ./scripts/create-eso-vault-token.sh"
echo "3. Apply ESO configurations: kubectl apply -f infrastructure/eso/"