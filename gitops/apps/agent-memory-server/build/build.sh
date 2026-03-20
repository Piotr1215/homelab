#!/usr/bin/env bash
set -eo pipefail

# Build custom agent-memory-server image with patches
# Patches add pattern/decision memory_type variants (not yet upstream)
# Previous SSE/transport patches are now upstream as of 2026-03
#
# Usage: ./build.sh [tag]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-latest-custom-v12}"
IMAGE="piotrzan/agent-memory-server:${TAG}"
UPSTREAM="https://github.com/redis/agent-memory-server.git"
UPSTREAM_REF="fd73560"  # pin: upstream v0.14.0 (2026-03-19)
BUILD_DIR=$(mktemp -d)

trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Cloning upstream ${UPSTREAM} (ref: ${UPSTREAM_REF})..."
git clone "$UPSTREAM" "$BUILD_DIR"
cd "$BUILD_DIR"
git checkout "$UPSTREAM_REF"

echo "Applying patches..."
git apply "${SCRIPT_DIR}/mcp-patches.patch"

echo "Preparing Dockerfile (stripping BuildKit cache mounts)..."
sed 's/--mount=type=cache[^ ]* //g' Dockerfile > Dockerfile.patched

echo "Building ${IMAGE}..."
docker build --no-cache -f Dockerfile.patched --target standard -t "$IMAGE" .

echo "Done. Push with: docker push ${IMAGE}"
