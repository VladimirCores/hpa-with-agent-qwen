#!/bin/bash
# =============================================================================
# Step 03: Install Metrics Server
# =============================================================================
# Installs Metrics Server for resource metrics and HPA functionality.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[3/5] Installing Metrics Server $METRICS_SERVER_VERSION..."
echo ""

# Check if metrics-server already exists
if kubectl get pods -n kube-system -l k8s-app=metrics-server &>/dev/null; then
    MS_PODS=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | wc -l)
    if (( MS_PODS > 0 )); then
        echo "  Metrics-server already installed ($MS_PODS pods)"
        echo "  ✓ Skipped"
        exit 0
    fi
fi

# Install metrics-server
echo "  Installing metrics-server $METRICS_SERVER_VERSION..."
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml"

# Patch for Talos (disable TLS verification for kubelet)
echo "  Patching for Talos compatibility..."
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
    {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"},
    {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}
]' 2>/dev/null || true

# Wait for metrics-server
echo "  Waiting for metrics-server..."
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s 2>/dev/null || {
    echo "  WARNING: metrics-server not ready within timeout"
}

echo ""
echo "  ✓ Metrics-server installed"
echo ""
