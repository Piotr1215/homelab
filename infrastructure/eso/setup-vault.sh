#!/bin/bash

echo "Waiting for Vault pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s

echo "Port-forwarding Vault..."
kubectl port-forward -n vault svc/vault 8200:8200 &
PF_PID=$!
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'

echo "Getting root token from Vault dev mode..."
ROOT_TOKEN=$(kubectl logs -n vault vault-0 | grep 'Root Token:' | awk '{print $3}')
export VAULT_TOKEN=$ROOT_TOKEN

echo "Root Token: $ROOT_TOKEN"

echo "Enabling KV v2 secrets engine..."
vault secrets enable -path=secret kv-v2

echo "Creating test secrets..."
vault kv put secret/test-app/config username="admin" password="secretpass123" api_key="abc123xyz"

echo "Creating policy for ESO..."
cat <<EOF | vault policy write eso-policy -
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

echo "Enabling Kubernetes auth..."
vault auth enable kubernetes

echo "Configuring Kubernetes auth..."
vault write auth/kubernetes/config \
    kubernetes_host="https://192.168.178.78:6443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

echo "Creating role for ESO..."
vault write auth/kubernetes/role/eso-role \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=eso-policy \
    ttl=1h

echo "Creating token for ESO..."
ESO_TOKEN=$(vault token create -policy=eso-policy -format=json | jq -r '.auth.client_token')

echo "Creating Kubernetes secret with Vault token..."
kubectl create secret generic vault-token \
    --from-literal=token=$ESO_TOKEN \
    -n external-secrets

echo "Vault setup complete!"
echo "Vault UI available at: http://127.0.0.1:8200"
echo "Root Token: $ROOT_TOKEN"

kill $PF_PID