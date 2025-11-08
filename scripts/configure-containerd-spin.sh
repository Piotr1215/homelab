#!/bin/bash
# Script to configure containerd for Spin runtime on a Kubernetes node
# Run this script with sudo on the target node

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}===== Containerd Spin Runtime Configuration =====${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Check if containerd is installed
if ! command -v containerd &> /dev/null; then
    echo -e "${RED}Error: containerd is not installed${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 1: Checking for containerd-shim-spin...${NC}"
if [ ! -f /usr/local/bin/containerd-shim-spin-v2 ]; then
    echo -e "${RED}Error: containerd-shim-spin-v2 not found${NC}"
    echo "Please ensure the spin-node-installer DaemonSet has run on this node"
    echo "Or manually install from: https://github.com/spinkube/containerd-shim-spin/releases"
    exit 1
fi
echo -e "${GREEN}✓ containerd-shim-spin-v2 found${NC}"
echo ""

# Backup existing config
CONTAINERD_CONFIG="/etc/containerd/config.toml"
BACKUP_FILE="${CONTAINERD_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"

echo -e "${YELLOW}Step 2: Backing up containerd config...${NC}"
cp "$CONTAINERD_CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: ${BACKUP_FILE}${NC}"
echo ""

echo -e "${YELLOW}Step 3: Checking if Spin runtime is already configured...${NC}"
if grep -q "io.containerd.spin.v2" "$CONTAINERD_CONFIG"; then
    echo -e "${YELLOW}⚠ Spin runtime already configured in containerd${NC}"
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 0
    fi
else
    echo -e "${GREEN}✓ Spin runtime not yet configured${NC}"
fi
echo ""

echo -e "${YELLOW}Step 4: Adding Spin runtime configuration...${NC}"

# Check if the runtimes section exists
if ! grep -q '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\]' "$CONTAINERD_CONFIG"; then
    echo -e "${RED}Error: Could not find runtimes section in containerd config${NC}"
    echo "Your containerd config might have a non-standard structure"
    echo "Please add the following manually:"
    echo ""
    echo '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.spin]'
    echo '  runtime_type = "io.containerd.spin.v2"'
    exit 1
fi

# Create a temporary file with the new configuration
cat > /tmp/spin-runtime.toml <<'EOF'

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.spin]
      runtime_type = "io.containerd.spin.v2"
EOF

# Find the line with the runtimes section and append after it
# This is a safe way to add the configuration
LINE_NUM=$(grep -n '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\]' "$CONTAINERD_CONFIG" | head -1 | cut -d: -f1)

if [ -z "$LINE_NUM" ]; then
    echo -e "${RED}Error: Could not determine insertion point${NC}"
    exit 1
fi

# Insert the configuration
{
    head -n "$LINE_NUM" "$CONTAINERD_CONFIG"
    cat /tmp/spin-runtime.toml
    tail -n +$((LINE_NUM + 1)) "$CONTAINERD_CONFIG"
} > /tmp/config.toml.new

mv /tmp/config.toml.new "$CONTAINERD_CONFIG"
rm /tmp/spin-runtime.toml

echo -e "${GREEN}✓ Configuration added${NC}"
echo ""

echo -e "${YELLOW}Step 5: Validating containerd configuration...${NC}"
if containerd config dump > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Configuration is valid${NC}"
else
    echo -e "${RED}✗ Configuration validation failed${NC}"
    echo "Restoring backup..."
    cp "$BACKUP_FILE" "$CONTAINERD_CONFIG"
    exit 1
fi
echo ""

echo -e "${YELLOW}Step 6: Restarting containerd...${NC}"
systemctl restart containerd

# Wait for containerd to be ready
sleep 3

if systemctl is-active --quiet containerd; then
    echo -e "${GREEN}✓ containerd restarted successfully${NC}"
else
    echo -e "${RED}✗ containerd failed to restart${NC}"
    echo "Restoring backup..."
    cp "$BACKUP_FILE" "$CONTAINERD_CONFIG"
    systemctl restart containerd
    exit 1
fi
echo ""

echo -e "${YELLOW}Step 7: Verifying configuration...${NC}"
if containerd config dump | grep -q "io.containerd.spin.v2"; then
    echo -e "${GREEN}✓ Spin runtime is configured${NC}"
else
    echo -e "${RED}✗ Verification failed${NC}"
    exit 1
fi
echo ""

echo -e "${GREEN}===== Configuration Complete! =====${NC}"
echo ""
echo "Containerd is now configured to run Spin applications."
echo ""
echo "Next steps:"
echo "1. Label this node: kubectl label node \$(hostname) spin=true"
echo "2. Verify RuntimeClass exists: kubectl get runtimeclass wasmtime-spin-v2"
echo "3. Deploy a SpinApp: kubectl apply -f gitops/apps/spin-example-app.yaml"
echo ""
echo "Backup saved at: ${BACKUP_FILE}"
echo ""
echo "To verify the Spin runtime is working:"
echo "  kubectl get pods -A -o wide | grep spin"
