#!/bin/bash

# Script to create Kubernetes secrets for homelab applications
# This script reads secrets from environment variables (set in .envrc)

set -e

echo "Creating secrets for homelab applications..."

# Ensure required environment variables are set
if [ -z "$HOMEPAGE_VAR_PROXMOX_PASSWORD" ] || [ -z "$HOMEPAGE_VAR_ARGOCD_TOKEN" ]; then
    echo "Error: Required environment variables not set. Please source .envrc first."
    echo "Run: direnv allow"
    exit 1
fi

# Create namespaces if they don't exist
kubectl create namespace homepage --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

# Homepage secrets from environment variables
echo "Creating homepage secrets..."
kubectl create secret generic homepage-secrets \
  --namespace=homepage \
  --from-literal=proxmox-password="${HOMEPAGE_VAR_PROXMOX_PASSWORD}" \
  --from-literal=argocd-token="${HOMEPAGE_VAR_ARGOCD_TOKEN}" \
  --from-literal=portainer-key="${HOMEPAGE_VAR_PORTAINER_KEY}" \
  --from-literal=grafana-password="${HOMEPAGE_VAR_GRAFANA_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# MinIO secrets from environment variables
echo "Creating MinIO secrets..."
kubectl create secret generic minio-secrets \
  --namespace=minio \
  --from-literal=root-user="${MINIO_ROOT_USER}" \
  --from-literal=root-password="${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Synology NAS secrets from environment variables
if [ -n "$SYNOLOGY_PASSWORD" ]; then
    echo "Creating Synology NAS secrets..."
    kubectl create secret generic synology-secrets \
      --namespace=default \
      --from-literal=password="${SYNOLOGY_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Secrets creation complete!"