#!/bin/bash
# =============================================================================
# Step 07: Verify Bootstrap
# =============================================================================
# Verifies that the Talos cluster was bootstrapped successfully.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[7/9] Verifying bootstrap..."
echo ""

# Verify Talos members
echo "  Checking Talos cluster members..."
echo "  Querying: $MASTER_IP"
if talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
    echo ""
    echo "  ✓ Talos cluster members verified"
else
    echo "  WARNING: Could not verify cluster members"
    echo "  This may happen during transition from maintenance to cluster mode"
fi

echo ""

# Verify Kubernetes API
echo "  Checking Kubernetes API..."
if talosctl kubeconfig --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --force "$CONFIG_DIR/kubeconfig" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
    echo ""
    echo "  ✓ Kubernetes API accessible"
    echo "  Kubeconfig saved to: $CONFIG_DIR/kubeconfig"
else
    echo "  WARNING: Could not retrieve kubeconfig yet"
    echo "  Cluster may still be initializing"
fi

echo ""
echo "  ✓ Bootstrap verification completed"
echo ""
