#!/bin/bash
# Ultimate Cluster Recovery Script - One command to rule them all!
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
ARGOCD_VERSION="v2.11.0"
ARGOCD_NAMESPACE="argocd"
REPO_URL="https://github.com/Piotr1215/homelab"

echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}     🚀 ULTIMATE CLUSTER RECOVERY - Make Coffee Edition 🚀      ${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Function to wait for deployment
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    echo -e "${YELLOW}⏳ Waiting for $deployment in $namespace...${NC}"
    kubectl wait --for=condition=available --timeout=${timeout}s \
        deployment/$deployment -n $namespace 2>/dev/null || true
}

# Function to wait for pods
wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    
    echo -e "${YELLOW}⏳ Waiting for pods with label $label in $namespace...${NC}"
    kubectl wait --for=condition=ready pod \
        -l $label -n $namespace --timeout=${timeout}s 2>/dev/null || true
}

# Step 1: Check cluster connectivity
echo -e "${BLUE}[Step 1/7] Checking cluster connectivity...${NC}"
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to cluster. Please ensure KUBECONFIG is set.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to cluster${NC}"

# Step 2: Check/Install MetalLB if needed
echo -e "${BLUE}[Step 2/8] Checking MetalLB...${NC}"
if kubectl get namespace metallb-system &>/dev/null; then
    echo -e "${YELLOW}MetalLB already installed, skipping${NC}"
else
    echo "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
    sleep 10
    kubectl apply -f gitops/infra/metallb-l2-config.yaml
fi

# Step 3: Install ArgoCD
echo -e "${BLUE}[Step 3/8] Installing ArgoCD...${NC}"
if kubectl get namespace $ARGOCD_NAMESPACE &>/dev/null; then
    echo -e "${YELLOW}ArgoCD namespace exists, skipping creation${NC}"
else
    kubectl create namespace $ARGOCD_NAMESPACE
fi

echo "Installing ArgoCD $ARGOCD_VERSION..."
kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml

# Wait for ArgoCD to be ready
wait_for_deployment $ARGOCD_NAMESPACE "argocd-server" 300
wait_for_deployment $ARGOCD_NAMESPACE "argocd-repo-server" 300
wait_for_deployment $ARGOCD_NAMESPACE "argocd-applicationset-controller" 300
echo -e "${GREEN}✓ ArgoCD installed${NC}"

# Step 4: Apply app-of-apps
echo -e "${BLUE}[Step 4/8] Applying app-of-apps...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: HEAD
    path: gitops/clusters/homelab
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
echo -e "${GREEN}✓ App-of-apps applied${NC}"

# Step 5: Wait for critical infrastructure
echo -e "${BLUE}[Step 5/8] Waiting for critical infrastructure...${NC}"
echo "This will take a few minutes. Perfect time for that coffee! ☕"

# Wait for External Secrets Operator
echo -e "${YELLOW}Waiting for External Secrets Operator...${NC}"
for i in {1..60}; do
    if kubectl get deployment -n external-secrets &>/dev/null; then
        echo -e "${GREEN}✓ External Secrets Operator found${NC}"
        break
    fi
    echo -n "."
    sleep 5
done

# Step 6: Check External Secrets Operator health
echo -e "${BLUE}[Step 6/8] Checking External Secrets Operator status...${NC}"
if kubectl get deployment -n external-secrets &>/dev/null; then
    ESO_READY=$(kubectl get deployment -n external-secrets -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "$ESO_READY" -gt 0 ]; then
        echo -e "${GREEN}✓ External Secrets Operator is ready${NC}"
        echo -e "${YELLOW}Note: Ensure Bitwarden credentials are configured (run: just patch-bitwarden)${NC}"
    else
        echo -e "${YELLOW}⚠ External Secrets Operator is not ready yet${NC}"
        echo "Waiting for ESO to become ready..."
        kubectl wait --for=condition=available --timeout=300s deployment -n external-secrets -l app.kubernetes.io/name=external-secrets 2>/dev/null || true
    fi
else
    echo -e "${YELLOW}External Secrets Operator not yet deployed, will be handled by ArgoCD${NC}"
fi

# Step 7: Sync all applications
echo -e "${BLUE}[Step 7/8] Syncing all applications...${NC}"
sleep 10  # Give ArgoCD time to discover apps

# Get all applications and sync them
apps=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$apps" ]; then
    for app in $apps; do
        echo -e "${YELLOW}Syncing $app...${NC}"
        kubectl patch application $app -n argocd --type merge -p '{"operation":{"sync":{"prune":true,"syncOptions":["CreateNamespace=true"]}}}' 2>/dev/null || true
    done
fi

# Step 8: Final status check
echo -e "${BLUE}[Step 8/8] Final status check...${NC}"
sleep 20

# Check ArgoCD applications
echo -e "${YELLOW}ArgoCD Applications Status:${NC}"
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Check key services
echo ""
echo -e "${YELLOW}Key Services:${NC}"
kubectl get svc -A | grep LoadBalancer | awk '{printf "%-20s %-30s %s\n", $2, $1, $5}'

# Summary
echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}🎉 CLUSTER RECOVERY COMPLETE! 🎉${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Configure Bitwarden credentials: just patch-bitwarden"
echo "2. Check ArgoCD UI: http://$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")"
echo "3. Check Homepage: http://$(kubectl get svc homepage -n homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")"
echo ""
echo -e "${GREEN}Your cluster is ready! Enjoy your coffee! ☕${NC}"