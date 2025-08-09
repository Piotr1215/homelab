#!/bin/bash

echo "Setting up ArgoCD..."

# Apply Terraform
terraform init
terraform apply -auto-approve

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

echo "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Admin password: $ARGOCD_PASSWORD"

echo "Getting ArgoCD LoadBalancer IP..."
ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ArgoCD UI: http://$ARGOCD_IP"

echo "Login with:"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"

echo ""
echo "To set up GitOps, update the repoURL in gitops/clusters/homelab/*.yaml files"
echo "Then apply: kubectl apply -f ../gitops/clusters/homelab/"