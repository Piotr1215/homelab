#!/bin/bash
# Script to automatically update Homepage with LoadBalancer IPs

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Homepage LoadBalancer IP Updater ===${NC}"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Get Homepage LoadBalancer IP
HOMEPAGE_IP=$(kubectl get svc homepage -n homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -z "$HOMEPAGE_IP" ]; then
    echo -e "${YELLOW}Warning: Homepage LoadBalancer IP not found${NC}"
    HOMEPAGE_IP="pending"
fi

# Get other service IPs
ARGOCD_IP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
GRAFANA_IP=$(kubectl get svc kube-prometheus-stack-grafana -n prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
PROMETHEUS_IP=$(kubectl get svc kube-prometheus-stack-prometheus -n prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
VAULT_IP=$(kubectl get svc vault-ui -n vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
MINIO_IP=$(kubectl get svc minio -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
KAGENT_IP=$(kubectl get svc kagent-ui -n kagent -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

echo -e "${GREEN}Found LoadBalancer IPs:${NC}"
echo "  Homepage: ${HOMEPAGE_IP:-not assigned}"
echo "  ArgoCD: ${ARGOCD_IP:-not assigned}"
echo "  Grafana: ${GRAFANA_IP:-not assigned}"
echo "  Prometheus: ${PROMETHEUS_IP:-not assigned}"
echo "  Vault: ${VAULT_IP:-not assigned}"
echo "  MinIO: ${MINIO_IP:-not assigned}"
echo "  Kagent: ${KAGENT_IP:-not assigned}"

# Function to update ConfigMap
update_configmap() {
    local namespace=$1
    local configmap=$2
    local key=$3
    local old_pattern=$4
    local new_value=$5
    
    if [ -n "$new_value" ] && [ "$new_value" != "pending" ]; then
        echo -e "${YELLOW}Updating $configmap in $namespace...${NC}"
        
        # Get current config
        kubectl get configmap $configmap -n $namespace -o jsonpath="{.data.$key}" > /tmp/config.yaml
        
        # Update URLs with new IPs
        sed -i "s|$old_pattern|$new_value|g" /tmp/config.yaml
        
        # Update the ConfigMap
        kubectl create configmap $configmap-temp --from-file=$key=/tmp/config.yaml -n $namespace --dry-run=client -o yaml | \
            kubectl replace -f -
        
        rm /tmp/config.yaml
    fi
}

# Update Homepage ConfigMap if needed
if [ -n "$HOMEPAGE_IP" ] && [ "$HOMEPAGE_IP" != "pending" ]; then
    echo -e "${GREEN}Updating Homepage allowed hosts...${NC}"
    
    # Update HOMEPAGE_ALLOWED_HOSTS in deployment
    kubectl set env deployment/homepage -n homepage HOMEPAGE_ALLOWED_HOSTS="$HOMEPAGE_IP"
    
    # Restart Homepage to pick up changes
    kubectl rollout restart deployment/homepage -n homepage
    
    echo -e "${GREEN}Homepage updated with IP: $HOMEPAGE_IP${NC}"
fi

# Generate service URLs for Homepage
cat <<EOF > /tmp/homepage-services-update.yaml
---
# This file contains the updated service URLs for Homepage
# Apply these changes to the Homepage ConfigMap services.yaml

# External URLs (for user access via browser):
argocd_url: ${ARGOCD_IP:+http://$ARGOCD_IP}
grafana_url: ${GRAFANA_IP:+http://$GRAFANA_IP}
prometheus_url: ${PROMETHEUS_IP:+http://$PROMETHEUS_IP:9090}
vault_url: ${VAULT_IP:+http://$VAULT_IP:8200}
minio_url: ${MINIO_IP:+http://$MINIO_IP:9001}
kagent_url: ${KAGENT_IP:+http://$KAGENT_IP}

# Internal URLs (for widget data fetching):
# These should remain as cluster-internal addresses
prometheus_internal: http://kube-prometheus-stack-prometheus.prometheus.svc.cluster.local:9090
grafana_internal: http://kube-prometheus-stack-grafana.prometheus.svc.cluster.local:80
vault_internal: http://vault.vault.svc.cluster.local:8200
kagent_internal: http://kagent-ui.kagent.svc.cluster.local
EOF

echo -e "${GREEN}Service URLs saved to /tmp/homepage-services-update.yaml${NC}"
echo -e "${YELLOW}Note: You may need to manually update the Homepage ConfigMap with these values${NC}"

# Optionally patch Homepage ConfigMap directly (commented out for safety)
# echo -e "${YELLOW}Patching Homepage ConfigMap...${NC}"
# kubectl get cm homepage -n homepage -o yaml | \
#     sed "s|192\.168\.[0-9]\+\.[0-9]\+|$HOMEPAGE_IP|g" | \
#     kubectl apply -f -

echo -e "${GREEN}=== Update Complete ===${NC}"
echo ""
echo "To access services:"
[ -n "$HOMEPAGE_IP" ] && [ "$HOMEPAGE_IP" != "pending" ] && echo "  Homepage: http://$HOMEPAGE_IP"
[ -n "$ARGOCD_IP" ] && echo "  ArgoCD: http://$ARGOCD_IP"
[ -n "$GRAFANA_IP" ] && echo "  Grafana: http://$GRAFANA_IP"
[ -n "$PROMETHEUS_IP" ] && echo "  Prometheus: http://$PROMETHEUS_IP:9090"
[ -n "$VAULT_IP" ] && echo "  Vault: http://$VAULT_IP:8200"
[ -n "$MINIO_IP" ] && echo "  MinIO Console: http://$MINIO_IP:9001"
[ -n "$KAGENT_IP" ] && echo "  Kagent: http://$KAGENT_IP"