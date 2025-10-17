#!/usr/bin/env bash
set -eo pipefail

# Build and push vCluster YAML MCP Server Docker image

DOCKER_USER="${DOCKER_USER:-piotrzan}"
IMAGE_NAME="vcluster-yaml-mcp-server"
VERSION="${VERSION:-latest}"
PROJECT_DIR="/home/decoder/dev/vcluster-yaml-mcp-server"

echo "🚀 Building vCluster YAML MCP Server"
echo "   Docker user: $DOCKER_USER"
echo "   Image: $IMAGE_NAME:$VERSION"
echo ""

# Change to project directory
cd "$PROJECT_DIR"

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
  echo "📦 Installing dependencies..."
  npm install
fi

# Build Docker image
echo "🐳 Building Docker image..."
docker build -t "$DOCKER_USER/$IMAGE_NAME:$VERSION" .

# Push to registry
echo "⬆️  Pushing to Docker Hub..."
docker push "$DOCKER_USER/$IMAGE_NAME:$VERSION"

echo ""
echo "✅ Build complete!"
echo "   Image: $DOCKER_USER/$IMAGE_NAME:$VERSION"
echo ""
echo "Next steps:"
echo "1. ArgoCD will automatically sync the deployment"
echo "2. Or manually: kubectl rollout restart deployment/vcluster-yaml-mcp -n default"
