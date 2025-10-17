#!/usr/bin/env bash
set -eo pipefail

# Setup Cloudflare Tunnel for vCluster YAML MCP Server

echo "🔐 Cloudflare Tunnel Setup for vCluster YAML MCP Server"
echo ""

# Check prerequisites
if ! command -v cloudflared &> /dev/null; then
    echo "❌ cloudflared not found. Please install it first:"
    echo "   https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install it first."
    exit 1
fi

echo "✅ Prerequisites checked"
echo ""

# Step 1: Login
echo "📝 Step 1: Login to Cloudflare"
echo "   This will open your browser..."
cloudflared tunnel login
echo ""

# Step 2: Create tunnel
echo "🚇 Step 2: Creating Cloudflare tunnel..."
TUNNEL_OUTPUT=$(cloudflared tunnel create vcluster-yaml-mcp 2>&1)
echo "$TUNNEL_OUTPUT"

# Extract tunnel ID
TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP 'with id \K[a-f0-9-]+' || echo "")

if [ -z "$TUNNEL_ID" ]; then
    echo "❌ Failed to extract tunnel ID. Check if tunnel already exists:"
    cloudflared tunnel list
    echo ""
    read -p "Enter your tunnel ID manually: " TUNNEL_ID
fi

echo ""
echo "✅ Tunnel ID: $TUNNEL_ID"
echo ""

# Step 3: Find credentials file
CREDS_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
if [ ! -f "$CREDS_FILE" ]; then
    echo "❌ Credentials file not found at: $CREDS_FILE"
    echo "   Looking for any credentials files..."
    find "$HOME/.cloudflared" -name "*.json" -type f 2>/dev/null || echo "No JSON files found"
    exit 1
fi

echo "✅ Credentials file found: $CREDS_FILE"
echo ""

# Step 4: Create Kubernetes secret
echo "☸️  Step 3: Creating Kubernetes secret..."
kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic tunnel-credentials-vcluster-yaml \
  --from-file=credentials.json="$CREDS_FILE" \
  -n cloudflare-tunnel \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secret created"
echo ""

# Step 5: Update ConfigMap with tunnel ID
echo "📝 Step 4: Updating tunnel configuration..."
HOMELAB_DIR="/home/decoder/dev/homelab"
MANIFEST_FILE="$HOMELAB_DIR/gitops/apps/cloudflare-tunnel-vcluster-yaml.yaml"

# Create backup
cp "$MANIFEST_FILE" "$MANIFEST_FILE.bak"

# Update tunnel ID in ConfigMap
sed -i "s/REPLACE_WITH_TUNNEL_ID/$TUNNEL_ID/g" "$MANIFEST_FILE"

echo "✅ ConfigMap updated in: $MANIFEST_FILE"
echo ""

# Step 6: Configure DNS
echo "📋 Step 5: DNS Configuration"
echo ""
echo "⚠️  IMPORTANT: Configure DNS in Cloudflare Dashboard"
echo ""
echo "Go to: https://dash.cloudflare.com"
echo "1. Select domain: cloudrumble.net"
echo "2. Navigate to: DNS → Records"
echo "3. Add CNAME record:"
echo "   - Type: CNAME"
echo "   - Name: vcluster-yaml"
echo "   - Target: $TUNNEL_ID.cfargotunnel.com"
echo "   - Proxy status: Proxied (🟠 orange cloud)"
echo "   - TTL: Auto"
echo ""
echo "OR run this command:"
echo "   cloudflared tunnel route dns vcluster-yaml-mcp vcluster-yaml.cloudrumble.net"
echo ""

read -p "Press Enter when DNS is configured..."

# Step 7: Commit and push (GitOps)
echo ""
echo "📝 Step 6: Commit to Git (GitOps)"
echo ""
cd "$HOMELAB_DIR"

git add gitops/apps/cloudflare-tunnel-vcluster-yaml.yaml
git commit -m "feat: add Cloudflare tunnel for vcluster-yaml-mcp-server

Tunnel ID: $TUNNEL_ID
DNS: vcluster-yaml.cloudrumble.net
"

echo ""
read -p "Push to GitHub? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git push
    echo "✅ Pushed to GitHub"
    echo "   ArgoCD will automatically sync in ~3 minutes"
    echo "   Or manually sync: kubectl patch application apps -n argocd --type merge -p '{\"spec\":{\"source\":{\"targetRevision\":\"HEAD\"}}}'"
fi

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Next steps:"
echo "1. Wait for DNS propagation (2-5 minutes)"
echo "2. Wait for ArgoCD to sync (or manually sync)"
echo "3. Test: curl https://vcluster-yaml.cloudrumble.net/health"
echo "4. Add to Claude config:"
echo ""
echo '   {
     "mcpServers": {
       "vcluster-yaml": {
         "type": "http",
         "url": "https://vcluster-yaml.cloudrumble.net/mcp"
       }
     }
   }'
echo ""
echo "📖 Full documentation: /home/decoder/dev/vcluster-yaml-mcp-server/docs/DEPLOYMENT.md"
