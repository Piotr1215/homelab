#!/usr/bin/env bash
set -eo pipefail

# Build custom agent-memory-server image with MCP patches
# Patches fix two issues with Claude Code SSE transport:
#   1. stateless=True - skip MCP init handshake (Claude Code subagents don't complete it)
#   2. return Response() - prevent TypeError on SSE client disconnect
#
# Usage: ./build.sh [tag]
#   tag defaults to "0.13.2-custom-v2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-0.13.2-custom-v6}"
IMAGE="piotrzan/agent-memory-server:${TAG}"
UPSTREAM="https://github.com/redis/agent-memory-server.git"
UPSTREAM_REF="main"
BUILD_DIR=$(mktemp -d)

trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Cloning upstream ${UPSTREAM} (ref: ${UPSTREAM_REF})..."
git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM" "$BUILD_DIR"

echo "Applying MCP patches..."
cd "$BUILD_DIR"
git apply "${SCRIPT_DIR}/mcp-patches.patch"

echo "Preparing Dockerfile (stripping BuildKit cache mounts)..."
sed 's/--mount=type=cache[^ ]* //g' Dockerfile > Dockerfile.patched

echo "Building ${IMAGE}..."
docker build --no-cache -f Dockerfile.patched --target standard -t "$IMAGE" .

echo "Done. Push with: docker push ${IMAGE}"
