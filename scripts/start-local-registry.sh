#!/bin/bash
# =============================================================================
# Start Local Registry using Podman
# =============================================================================
# Runs a local container registry on port 5000 to cache/mirror images.
# =============================================================================

set -e

REGISTRY_PORT=5000
REGISTRY_NAME="local-registry"

echo "Checking for podman..."
if ! command -v podman &>/dev/null; then
    echo "ERROR: podman is not installed. Please install podman first."
    exit 1
fi

echo "Checking if registry container is already running..."
if podman ps -q -f name="$REGISTRY_NAME" | grep -q .; then
    echo "✓ Registry '$REGISTRY_NAME' is already running."
    exit 0
fi

echo "Checking if registry container exists but stopped..."
if podman ps -aq -f name="$REGISTRY_NAME" | grep -q .; then
    echo "Starting stopped registry container '$REGISTRY_NAME'..."
    podman start "$REGISTRY_NAME"
    echo "✓ Registry started."
    exit 0
fi

echo "Starting new registry container '$REGISTRY_NAME' on port $REGISTRY_PORT..."
podman run -d \
  -p $REGISTRY_PORT:5000 \
  --name "$REGISTRY_NAME" \
  --restart=always \
  docker.io/library/registry:2

echo "✓ Local registry is now running on port $REGISTRY_PORT."
