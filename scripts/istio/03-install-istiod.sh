#!/bin/bash
# =============================================================================
# Istio Step 03: Install Istiod (Control Plane)
# =============================================================================
# Installs the istio/istiod Helm chart deploying the Istio control plane.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[3/7] Installing Istiod (control plane)..."
echo ""

# Install istiod
echo -n "  Installing istiod... "
if helm upgrade --install istiod istio/istiod \
    --namespace "$ISTIO_NAMESPACE" \
    --wait \
    --timeout 300s \
    --set global.hub="docker.io/istio" \
    --set global.tag="$ISTIO_VERSION" \
    --set global.proxy.image="proxyv2" \
    --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE="true" \
    --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_AUTO_ALLOCATE="true" \
    --set meshConfig.accessLogFile="/dev/stdout" \
    --set meshConfig.enableTracing=true \
    --set pilot.autoscaleMin=1 \
    --set pilot.autoscaleMax=3 \
    --set pilot.resources.requests.cpu=100m \
    --set pilot.resources.requests.memory=256Mi \
    --set pilot.resources.limits.cpu=500m \
    --set pilot.resources.limits.memory=1Gi \
    2>/dev/null; then
    echo "✓"
else
    echo "ERROR: Failed to install istiod"
    exit 1
fi

# Wait for deployment
echo -n "  Waiting for istiod deployment to be ready... "
if kubectl wait deployment -n "$ISTIO_NAMESPACE" istiod --for=condition=Available --timeout=180s &>/dev/null; then
    echo "✓"
else
    echo "ERROR: istiod did not become ready"
    exit 1
fi

# Show istiod pod
echo ""
echo "Istiod pods:"
kubectl get pods -n "$ISTIO_NAMESPACE" -l app=istiod
echo ""

echo "Istiod installation complete"
echo ""
