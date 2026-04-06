#!/bin/bash
# =============================================================================
# Step 02: Install Flannel CNI
# =============================================================================
# Installs Flannel CNI as a simple alternative.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/5] Installing Flannel CNI..."
echo ""

# Check if Flannel already exists
if kubectl get pods -n kube-system -l app=flannel &>/dev/null; then
    FLANNEL_PODS=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | wc -l)
    if (( FLANNEL_PODS > 0 )); then
        echo "  Flannel already installed ($FLANNEL_PODS pods)"
        echo "  ✓ Skipped"
        exit 0
    fi
fi

# Check if any CNI is installed
if kubectl get pods -n kube-system | grep -E "(calico|cilium|weave)" &>/dev/null; then
    echo "  Another CNI detected, skipping Flannel installation"
    echo "  ✓ Skipped"
    exit 0
fi

# Install Flannel
echo "  Installing Flannel..."
kubectl apply -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

# Wait for Flannel pods
echo "  Waiting for Flannel pods..."
kubectl wait --for=condition=ready pod -l app=flannel -n kube-system --timeout=120s 2>/dev/null || {
    echo "  WARNING: Flannel pods not ready within timeout"
}

echo ""
echo "  ✓ Flannel installed"
echo ""
