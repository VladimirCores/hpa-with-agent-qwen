#!/bin/bash
# =============================================================================
# Step 01: Check Prerequisites
# =============================================================================
# Verifies all required tools and cluster state are available.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[1/5] Checking prerequisites..."
echo ""

# Check kubectl
echo -n "  Checking kubectl... "
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    echo "  Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    echo "  Then: sudo install kubectl /usr/local/bin/"
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

# Check cluster connectivity
echo -n "  Checking cluster connectivity... "
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    echo "  Ensure cluster is bootstrapped: ./scripts/talos-bootstrap.sh"
    exit 1
fi
echo "✓ ($(kubectl config current-context 2>/dev/null || echo 'connected'))"

# Check nodes
echo -n "  Checking nodes... "
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if (( NODE_COUNT == 0 )); then
    echo "ERROR: No nodes registered in cluster"
    echo "  Wait for nodes to register: kubectl get nodes"
    exit 1
fi
echo "✓ ($NODE_COUNT nodes)"

# Check node readiness
echo -n "  Checking node readiness... "
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l || true)
if (( NOT_READY > 0 )); then
    echo "WARNING: $NOT_READY node(s) not ready yet"
    echo "  Wait and retry: kubectl get nodes"
    echo "  Checking node status anyway..."
else
    echo "✓ (all nodes Ready)"
fi

# Check for existing CNI
echo -n "  Checking existing CNI... "
CNI_PODS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -E "(cilium|calico|flannel)" | wc -l || true)
if (( CNI_PODS > 0 )); then
    CNI_TYPE=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -oE "(cilium|calico|flannel)" | head -1 || echo "unknown")
    echo "⚠ CNI detected: $CNI_TYPE ($CNI_PODS pods)"
    echo "  Script will handle CNI replacement if needed"
else
    echo "✓ (no CNI installed)"
fi

echo ""
echo "All prerequisites met"
echo ""
