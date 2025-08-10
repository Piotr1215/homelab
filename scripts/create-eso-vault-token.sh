#!/bin/bash

# Create Vault token for External Secrets Operator

set -e

# Source environment variables
if [ -f ".envrc" ]; then
    source .envrc
else
    echo "Error: .envrc file not found"
    exit 1
fi

echo "Creating Vault token for ESO..."

# Create a policy for ESO to read secrets
vault policy write eso-policy - <<EOF
path "homelab/*" {
  capabilities = ["read", "list"]
}
EOF

# Create a token with the ESO policy
ESO_TOKEN=$(vault token create -policy=eso-policy -format=json | jq -r '.auth.client_token')

echo "Creating Kubernetes secret with Vault token for ESO..."

# Create the token secret in each namespace that needs it
for namespace in homepage ***REMOVED*** default; do
    echo "Creating vault-token secret in namespace: $namespace"
    kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret generic vault-token \
        --namespace=$namespace \
        --from-literal=token="${ESO_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "✅ ESO Vault token created and stored in Kubernetes!"
echo ""
echo "Next step: Apply ESO configurations"
echo "kubectl apply -f infrastructure/eso/"