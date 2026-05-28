#!/bin/bash
# =============================================================================
# Istio Step 02: Install Istio Base (CRDs)
# =============================================================================
# Installs the istio/base Helm chart which provides Istio CRDs.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/7] Installing Istio base (CRDs)..."
echo ""

# Add/update Istio Helm repo
echo -n "  Adding/updating Istio Helm repository... "
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update 2>/dev/null
echo "✓"

# Create namespace if needed
echo -n "  Creating namespace $ISTIO_NAMESPACE... "
kubectl create namespace "$ISTIO_NAMESPACE" 2>/dev/null || true
echo "✓"

# Install istio/base
echo -n "  Installing istio/base... "
if helm upgrade --install istio-base istio/base \
    --namespace "$ISTIO_NAMESPACE" \
    --wait \
    --timeout 180s \
    --set global.imageTag="$ISTIO_VERSION" \
    2>/dev/null; then
    echo "✓"
else
    echo "ERROR: Failed to install istio/base"
    exit 1
fi

# Verify CRDs
echo -n "  Verifying Istio CRDs... "
if kubectl get crd -l app.kubernetes.io/part-of=istio 2>/dev/null | grep -q .; then
    CRD_COUNT=$(kubectl get crd -l app.kubernetes.io/part-of=istio --no-headers 2>/dev/null | wc -l)
    echo "✓ ($CRD_COUNT CRDs installed)"
else
    echo "⚠ (no CRDs found, may need a moment)"
fi

echo ""
echo "Istio base installation complete"
echo ""
