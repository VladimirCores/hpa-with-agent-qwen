#!/bin/bash
# =============================================================================
# Istio with Envoy Gateway Installation (Preview)
# =============================================================================
# This script is a placeholder for the upcoming Istio + Envoy Gateway install.
# See docs/04-Istio-Envoy-Gateway-Preview.md for details.
# =============================================================================

set -euo pipefail

echo "=== Istio with Envoy Gateway Installation (Preview) ==="
echo ""
echo "This script is under development."
echo ""
echo "For manual installation instructions, see:"
echo "  docs/04-Istio-Envoy-Gateway-Preview.md"
echo ""
echo "Prerequisites:"
echo "  1. Talos cluster bootstrapped (./scripts/talos-bootstrap.sh)"
echo "  2. Kubernetes components installed (./scripts/k8s-components.sh)"
echo "  3. Helm installed (https://helm.sh/docs/intro/install/)"
echo ""
echo "Quick preview of current cluster state:"
echo ""

# Check if kubectl is available
if command -v kubectl &>/dev/null; then
    echo "Kubernetes nodes:"
    kubectl get nodes 2>/dev/null || echo "  (cluster not accessible)"
    echo ""

    echo "Current namespaces:"
    kubectl get namespaces 2>/dev/null | head -10 || echo "  (unable to list)"
    echo ""

    echo "Existing Istio installation:"
    if kubectl get namespace istio-system &>/dev/null; then
        kubectl get pods -n istio-system 2>/dev/null || echo "  (no pods found)"
    else
        echo "  Not installed"
    fi
else
    echo "kubectl not installed. Please install kubectl first."
fi

echo ""
echo "=== Preview Complete ==="
