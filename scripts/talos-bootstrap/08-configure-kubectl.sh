#!/bin/bash
# =============================================================================
# Step 08: Configure kubectl
# =============================================================================
# Downloads kubeconfig from the cluster and configures kubectl.
# Always overwrites existing kubeconfig to avoid interactive prompts.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Always use a unique context name to avoid merge conflicts
CONTEXT_NAME="${CLUSTER_NAME:-talos-cluster}"

echo "[8/9] Configuring kubectl..."
echo "  Master: $MASTER_NAME ($MASTER_IP)"
echo "  Context: $CONTEXT_NAME"
echo ""

# Download kubeconfig (always overwrite)
echo "  Downloading kubeconfig from cluster..."
if talosctl kubeconfig \
    --nodes "$MASTER_IP" \
    --endpoints "$MASTER_IP" \
    --force \
    --force-context-name "$CONTEXT_NAME" \
    "$CONFIG_DIR/kubeconfig" \
    --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
    echo "  ✓ Kubeconfig downloaded to: $CONFIG_DIR/kubeconfig"
else
    echo "  ERROR: Failed to download kubeconfig"
    echo "  Cluster may still be initializing"
    echo "  Retry in 30s: talosctl kubeconfig --nodes $MASTER_IP --endpoints $MASTER_IP $CONFIG_DIR/kubeconfig"
    exit 1
fi

echo ""

# Verify kubectl works
echo "  Verifying kubectl access..."
if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl cluster-info 2>&1 | grep -q "Kubernetes control plane"; then
    echo "  ✓ kubectl access verified"
else
    echo "  WARNING: kubectl cluster-info failed"
    echo "  Cluster may still be initializing"
    echo "  Check cluster status: KUBECONFIG=$CONFIG_DIR/kubeconfig kubectl get nodes"
fi

echo ""
echo "  ✓ kubectl configured"
echo ""
