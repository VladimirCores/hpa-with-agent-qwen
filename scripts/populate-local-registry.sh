#!/bin/bash
# =============================================================================
# Populate Local Registry with K8s and Talos Images
# =============================================================================
# Pre-pulls common images and pushes them to the local registry.
# This speeds up Talos bootstrap and cluster operations.
# All cluster components will pull images from this local cache.
# =============================================================================

set -euo pipefail

# Source common setup to get versions and network info
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$STEP_DIR")"

# Try to source talos-bootstrap setup if available
if [[ -f "$STEP_DIR/talos-bootstrap/00-setup.sh" ]]; then
    source "$STEP_DIR/talos-bootstrap/00-setup.sh"
elif [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "WARNING: Could not find .env file, using defaults"
    NETWORK_IP="${NETWORK_IP:-192.168.123.1}"
fi

REGISTRY_URL="${NETWORK_IP}:5000"
# K8s version from script or env (default to 1.36.0 for Talos 1.13)
K8S_VERSION="${KUBERNETES_VERSION:-1.36.0}"
# Talos version from env (strip 'v' prefix if present)
TALOS_VERSION_CLEAN="${TALOS_VERSION#v}"
TALOS_VERSION_FULL="${TALOS_VERSION_CLEAN}.0"

echo "============================================================================="
echo "Populating Local Registry at $REGISTRY_URL"
echo "============================================================================="
echo "Talos Version: $TALOS_VERSION_FULL"
echo "K8s Version: $K8S_VERSION"
echo ""

# Verify registry is running
echo "Checking local registry status..."
if ! podman ps -q -f name="local-registry" | grep -q .; then
    echo "ERROR: Local registry is not running!"
    echo "Please start it first: $STEP_DIR/start-local-registry.sh"
    exit 1
fi
echo "✓ Local registry is running"
echo ""

# Statistics
TOTAL_IMAGES=0
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

# List of images to cache
# Format: "ORIGINAL_IMAGE"
declare -a IMAGES=(
    # =========================================================================
    # Talos Linux
    # =========================================================================
    "ghcr.io/siderolabs/installer:${TALOS_VERSION_FULL}"
    "ghcr.io/siderolabs/kubelet:v${K8S_VERSION}"
    
    # =========================================================================
    # Kubernetes Core Components
    # =========================================================================
    "registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    "registry.k8s.io/etcd:3.5.15-0"
    "registry.k8s.io/pause:3.10"
    "registry.k8s.io/coredns/coredns:v1.11.1"
    
    # =========================================================================
    # Cilium CNI (Default CNI for this cluster)
    # =========================================================================
    "quay.io/cilium/cilium:v${CILIUM_VERSION:-1.19.1}"
    "quay.io/cilium/operator-generic:v${CILIUM_VERSION:-1.19.1}"
    "quay.io/cilium/hubble-relay:v${CILIUM_VERSION:-1.19.1}"
    "quay.io/cilium/hubble-ui:v${CILIUM_VERSION:-1.19.1}"
    "quay.io/cilium/hubble-ui-backend:v${CILIUM_VERSION:-1.19.1}"
    "quay.io/cilium/cilium-init:v${CILIUM_VERSION:-1.19.1}"
    
    # =========================================================================
    # Calico CNI (Alternative CNI)
    # =========================================================================
    "docker.io/calico/node:v${CALICO_VERSION:-3.28.0}"
    "docker.io/calico/kube-controllers:v${CALICO_VERSION:-3.28.0}"
    "docker.io/calico/cni:v${CALICO_VERSION:-3.28.0}"
    "docker.io/calico/pod2daemon-flexvol:v${CALICO_VERSION:-3.28.0}"
    "docker.io/calico/typha:v${CALICO_VERSION:-3.28.0}"
    
    # =========================================================================
    # Flannel CNI (Simple Alternative CNI)
    # =========================================================================
    "docker.io/flannel/flannel-cni-plugin:v1.2.0"
    "docker.io/flannel/flannel:v${FLANNEL_VERSION:-v0.24.0}"
    
    # =========================================================================
    # Metrics Server
    # =========================================================================
    "registry.k8s.io/metrics-server/metrics-server:v${METRICS_SERVER_VERSION:-0.7.1}"
    
    # =========================================================================
    # MetalLB LoadBalancer
    # =========================================================================
    "quay.io/metallb/controller:v${METALLB_VERSION:-0.14.8}"
    "quay.io/metallb/speaker:v${METALLB_VERSION:-0.14.8}"
    
    # =========================================================================
    # Kubernetes Dashboard
    # =========================================================================
    "registry.k8s.io/dashboard/dashboard:v2.7.0"
    "registry.k8s.io/dashboard/metrics-scraper:v1.0.8"
    
    # =========================================================================
    # Istio Service Mesh (Optional)
    # =========================================================================
    "docker.io/istio/pilot:1.22.0"
    "docker.io/istio/proxyv2:1.22.0"
    "docker.io/istio/proxyv2:1.22.0-distroless"
    
    # =========================================================================
    # Envoy Gateway (Optional - for service exposure)
    # =========================================================================
    "docker.io/envoyproxy/gateway:v1.1.0"
    "docker.io/envoyproxy/envoy:v1.31.0"
    
    # =========================================================================
    # Infisical Secret Manager (Optional)
    # =========================================================================
    "docker.io/infisical/infisical:v0.60.0"
    "registry-1.docker.io/bitnamicharts/postgresql:15.5.0"
    
    # =========================================================================
    # Helm Chart Dependencies
    # =========================================================================
    "docker.io/library/registry:2"
    "quay.io/jetstack/cert-manager-controller:v1.15.0"
    "quay.io/jetstack/cert-manager-cainjector:v1.15.0"
    "quay.io/jetstack/cert-manager-webhook:v1.15.0"
)

# Helper function to check if image exists in local registry
image_exists_in_registry() {
    local target="$1"
    # Try to inspect the image in local storage first
    if podman image exists "$target" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Pull, Tag, and Push
for IMAGE in "${IMAGES[@]}"; do
    TOTAL_IMAGES=$((TOTAL_IMAGES + 1))
    echo ""
    echo "-----------------------------------------------------------------------------"
    echo "[$TOTAL_IMAGES] Processing: $IMAGE"
    echo "-----------------------------------------------------------------------------"

    # Check if already cached in local registry
    IMAGE_PATH=$(echo "$IMAGE" | cut -d'/' -f2-)
    TARGET="${REGISTRY_URL}/${IMAGE_PATH}"
    
    if image_exists_in_registry "$TARGET"; then
        echo "  ✓ Already cached in local registry"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Pull the image
    echo "  Pulling from remote registry..."
    if ! podman pull "$IMAGE" 2>&1; then
        echo "  ⚠ WARNING: Failed to pull $IMAGE, skipping..."
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Tag for local registry
    echo "  Tagging as $TARGET..."
    if ! podman tag "$IMAGE" "$TARGET" 2>&1; then
        echo "  ⚠ WARNING: Failed to tag $IMAGE as $TARGET"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Push to local registry
    echo "  Pushing to local registry at $REGISTRY_URL..."
    if ! podman push "$TARGET" --tls-verify=false 2>&1; then
        echo "  ⚠ WARNING: Failed to push $TARGET to local registry"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    echo "  ✓ Successfully cached"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

# Print summary
echo ""
echo "============================================================================="
echo "Registry Population Summary"
echo "============================================================================="
echo "Total images processed: $TOTAL_IMAGES"
echo "Successfully cached:    $SUCCESS_COUNT"
echo "Skipped (already present): $SKIPPED_COUNT"
echo "Failed:                 $FAILED_COUNT"
echo ""

if [[ $FAILED_COUNT -gt 0 ]]; then
    echo "⚠ Some images failed to cache. These components may need to pull from"
    echo "  remote registries when deployed. The cluster will still function,"
    echo "  but initial deployment may be slower for those components."
    echo ""
fi

echo "Local registry is ready at: http://${REGISTRY_URL}"
echo ""
echo "Next steps:"
echo "  1. Ensure Talos config includes registry mirrors (see scripts/talos-bootstrap/03-generate-configs.sh)"
echo "  2. Bootstrap your cluster: ./scripts/talos-bootstrap.sh"
echo "  3. Install k8s components: ./scripts/k8s-components.sh"
echo ""
echo "✓ Local registry population complete."
