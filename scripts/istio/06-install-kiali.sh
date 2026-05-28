#!/bin/bash
# =============================================================================
# Istio Step 06: Install Kiali (Optional)
# =============================================================================
# Installs Kiali service mesh visualization.
# Only installs when KIALA_ENABLED=true in .env.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[6/7] Installing Kiali (optional)..."
echo ""

if [[ "$KIALA_ENABLED" != "true" ]]; then
    echo "  KIALA_ENABLED=false — skipping Kiali installation"
    echo "  Set KIALA_ENABLED=true in .env to enable"
    echo ""
    exit 0
fi

# Check if Istio namespace exists
if ! kubectl get namespace "$ISTIO_NAMESPACE" &>/dev/null; then
    echo "  ⚠ Istio namespace not found — Kiali requires Istio."
    echo "    Install Istio first, then re-run."
    echo ""
    exit 0
fi

# Check if Kiali is already installed
if kubectl get deployment kiali -n "$ISTIO_NAMESPACE" &>/dev/null; then
    echo "  ✓ Kiali already installed"
    echo ""
    echo "  Kiali access:"
    echo "    Port-forward: kubectl port-forward -n $ISTIO_NAMESPACE svc/kiali 20001:20001"
    echo "    URL: http://localhost:20001"
    echo ""
    exit 0
fi

# Check helm
if ! command -v helm &>/dev/null; then
    echo "  ERROR: helm not found"
    exit 1
fi

# Add/update Kiali Helm repo
echo -n "  Adding/updating Kiali Helm repository... "
helm repo add kiali https://kiali.org/helm-charts 2>/dev/null || true
helm repo update 2>/dev/null
echo "✓"

# Install Kiali
echo -n "  Installing Kiali (anonymous auth)... "
if helm upgrade --install kiali kiali/kiali-server \
    --namespace "$ISTIO_NAMESPACE" \
    --set auth.strategy="anonymous" \
    --wait \
    --timeout 180s \
    2>/dev/null; then
    echo "✓"
else
    echo "ERROR: Failed to install Kiali"
    exit 1
fi

# Wait for deployment
echo -n "  Waiting for Kiali deployment... "
if kubectl wait deployment -n "$ISTIO_NAMESPACE" kiali --for=condition=Available --timeout=120s &>/dev/null; then
    echo "✓"
else
    echo "⚠ Kiali deployment did not become ready"
fi

# Show Kiali pods
echo ""
echo "Kiali pods:"
kubectl get pods -n "$ISTIO_NAMESPACE" -l app=kiali
echo ""

echo "Kiali access:"
echo "  Port-forward: kubectl port-forward -n $ISTIO_NAMESPACE svc/kiali 20001:20001"
echo "  URL: http://localhost:20001"
echo ""

echo "Kiali installation complete"
echo ""
