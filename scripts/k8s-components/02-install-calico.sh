#!/bin/bash
# =============================================================================
# Step 02: Install Calico CNI
# =============================================================================
# Installs Calico CNI as an alternative to Cilium.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/5] Installing Calico CNI $CALICO_VERSION..."
echo ""

# Check if Calico already exists
if kubectl get pods -n calico-system -l k8s-app=calico-node &>/dev/null; then
    CALICO_PODS=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
    if (( CALICO_PODS > 0 )); then
        echo "  Calico already installed ($CALICO_PODS pods)"
        echo "  ✓ Skipped"
        exit 0
    fi
fi

# Check if any CNI is installed
if kubectl get pods -n kube-system | grep -E "(flannel|cilium|weave)" &>/dev/null; then
    echo "  WARNING: Another CNI detected. Removing..."
    kubectl delete -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" --ignore-not-found 2>/dev/null || true
    
    # Remove kube-proxy if present
    kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found 2>/dev/null || true
fi

# Install Calico
echo "  Installing Calico $CALICO_VERSION..."
curl -o /tmp/calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

# Apply Calico
kubectl apply -f /tmp/calico.yaml

# Wait for Calico pods
echo "  Waiting for Calico pods..."
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s 2>/dev/null || {
    echo "  WARNING: Calico pods not ready within timeout"
}

rm -f /tmp/calico.yaml
echo ""
echo "  ✓ Calico installed"
echo ""
