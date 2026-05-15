#!/bin/bash
# =============================================================================
# Populate Local Registry with K8s and Talos Images
# =============================================================================
# Pre-pulls common images and pushes them to the local registry.
# This speeds up Talos bootstrap and cluster operations.
# =============================================================================

# Source common setup to get versions and network info
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Try to source talos-bootstrap setup if available
if [[ -f "$STEP_DIR/talos-bootstrap/00-setup.sh" ]]; then
    source "$STEP_DIR/talos-bootstrap/00-setup.sh"
elif [[ -f "./scripts/talos-bootstrap/00-setup.sh" ]]; then
    source "./scripts/talos-bootstrap/00-setup.sh"
else
    echo "ERROR: Could not find 00-setup.sh. Run from project root."
    exit 1
fi

REGISTRY_URL="${NETWORK_IP}:5000"
# K8s version from script or env (default to a safe 1.32.0 if not set)
# Note: scripts/talos-bootstrap/03-generate-configs.sh uses 1.36.0 as fallback
K8S_VERSION="${KUBERNETES_VERSION:-1.32.0}"
# Talos version from env
TALOS_VERSION_FULL="${TALOS_VERSION}.0"

echo "Populating local registry at $REGISTRY_URL..."
echo "Talos Version: $TALOS_VERSION_FULL"
echo "K8s Version: $K8S_VERSION"

# List of images to cache
# Format: "ORIGINAL_IMAGE"
IMAGES=(
    # Talos Installer
    "ghcr.io/siderolabs/installer:${TALOS_VERSION_FULL}"

    # Kubernetes Core (Standard K8s registry)
    "registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    "registry.k8s.io/etcd:3.5.15-0"
    "registry.k8s.io/pause:3.10"
    "registry.k8s.io/coredns/coredns:v1.11.1"

    # Cilium CNI (Commonly used in this project)
    "quay.io/cilium/cilium:v${CILIUM_VERSION}"
    "quay.io/cilium/operator-generic:v${CILIUM_VERSION}"
    "quay.io/cilium/hubble-relay:v${CILIUM_VERSION}"
    "quay.io/cilium/hubble-ui:v${CILIUM_VERSION}"
    "quay.io/cilium/hubble-ui-backend:v${CILIUM_VERSION}"

    # Metrics Server
    "registry.k8s.io/metrics-server/metrics-server:v${METRICS_SERVER_VERSION}"

    # MetalLB
    "quay.io/metallb/controller:v${METALLB_VERSION}"
    "quay.io/metallb/speaker:v${METALLB_VERSION}"
)

# Pull, Tag, and Push
for IMAGE in "${IMAGES[@]}"; do
    echo ""
    echo "--- Image: $IMAGE ---"

    if ! podman pull "$IMAGE"; then
        echo "  WARNING: Failed to pull $IMAGE, skipping..."
        continue
    fi

    # Target image name on local registry
    # We strip the registry part and prepend our local registry URL
    # This matches how Talos mirrors work: mirror."registry.com".endpoints = ["http://local:5000"]
    # When Talos pulls "registry.com/foo/bar", it requests "http://local:5000/foo/bar"

    # Extract path after the first slash (e.g. siderolabs/installer)
    IMAGE_PATH=$(echo "$IMAGE" | cut -d'/' -f2-)
    TARGET="${REGISTRY_URL}/${IMAGE_PATH}"

    echo "  Tagging as $TARGET..."
    podman tag "$IMAGE" "$TARGET"

    echo "  Pushing to $REGISTRY_URL..."
    if ! podman push "$TARGET" --tls-verify=false; then
        echo "  ERROR: Failed to push $TARGET"
    fi
done

echo ""
echo "✓ Local registry population complete."
