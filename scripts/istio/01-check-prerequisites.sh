#!/bin/bash
# =============================================================================
# Istio Step 01: Check Prerequisites
# =============================================================================
# Verifies helm, kubectl, cluster connectivity, and component compatibility.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[1/7] Checking prerequisites..."
echo ""

# Check kubectl
echo -n "  Checking kubectl... "
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    exit 1
fi
echo "✓ ($(kubectl version --client --short 2>/dev/null | head -1 || echo 'installed'))"

# Set kubeconfig if not already set
if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f "$DEFAULT_KUBECONFIG" ]]; then
        export KUBECONFIG="$DEFAULT_KUBECONFIG"
        echo "  Using kubeconfig: $KUBECONFIG"
    fi
fi

# Check helm
echo -n "  Checking helm... "
if ! command -v helm &>/dev/null; then
    echo "ERROR: helm not found"
    echo "  Install: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
echo "✓ ($(helm version --short 2>/dev/null || echo 'installed'))"

# Check cluster connectivity
echo -n "  Checking cluster connectivity... "
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    exit 1
fi
echo "✓ ($(kubectl config current-context 2>/dev/null || echo 'connected'))"

# Check nodes
echo -n "  Checking nodes... "
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if (( NODE_COUNT == 0 )); then
    echo "ERROR: No nodes registered"
    exit 1
fi
echo "✓ ($NODE_COUNT nodes)"

# Check node readiness
echo -n "  Checking node readiness... "
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l || true)
if (( NOT_READY > 0 )); then
    echo "WARNING: $NOT_READY node(s) not ready"
else
    echo "✓ (all nodes Ready)"
fi

# Check for existing Istio
echo -n "  Checking existing Istio installation... "
if kubectl get namespace "$ISTIO_NAMESPACE" &>/dev/null; then
    echo "⚠ Detected: namespace $ISTIO_NAMESPACE exists"
    echo "  Script will upgrade existing installation if needed"
else
    echo "✓ (not installed)"
fi

# Check for existing Envoy Gateway
echo -n "  Checking existing Envoy Gateway... "
if kubectl get namespace "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null; then
    echo "⚠ Detected: namespace $ENVOY_GATEWAY_NAMESPACE exists"
    echo "  Script will upgrade existing installation if needed"
else
    echo "✓ (not installed)"
fi

# Check Gateway API CRDs
echo -n "  Checking Gateway API CRDs... "
if kubectl get gatewayclasses &>/dev/null 2>&1; then
    echo "✓ (present)"
else
    echo "⚠ (will be installed with Envoy Gateway)"
fi

echo ""
echo "  Configuration:"
echo "    Istio version:        $ISTIO_VERSION"
echo "    Envoy Gateway vers.:  $ENVOY_GATEWAY_VERSION"
echo "    Envoy Gateway IP:     $ENVOY_GATEWAY_LB_IP"
echo "    Kiali enabled:        $KIALA_ENABLED"
echo ""

echo "All prerequisites met"
echo ""
