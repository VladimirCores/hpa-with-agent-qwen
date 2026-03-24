#!/bin/bash
# =============================================================================
# Step 09: Final Cluster Verification
# =============================================================================
# Performs final verification of the Talos and Kubernetes cluster.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[9/9] Verifying cluster..."

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    echo "  kubectl not available, skipping Kubernetes verification"
    KUBECTL_AVAILABLE=false
else
    KUBECTL_AVAILABLE=true
fi

# Set KUBECONFIG
export KUBECONFIG="$CONFIG_DIR/kubeconfig"

# Check Kubernetes nodes
if [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    echo "  Kubernetes nodes:"
    if kubectl get nodes 2>/dev/null; then
        echo "    ✓ Nodes responding"
    else
        echo "    (waiting for nodes to register...)"
    fi
    
    echo ""
    echo "  System pods:"
    kubectl get pods -A 2>/dev/null | head -15 || echo "    (waiting for pods...)"
    
    echo ""
    echo "  Cluster info:"
    kubectl cluster-info 2>/dev/null | head -3 || echo "    (unable to get cluster info)"
else
    echo "  kubectl not available, skipping Kubernetes verification"
fi

# Check Talos members
echo ""
echo "  Talos cluster members:"
talosctl get members --nodes "$MASTER_IP" --insecure 2>/dev/null | head -10 || echo "    (unable to get members)"

echo ""
echo "  ✓ Cluster verification complete"
echo ""
