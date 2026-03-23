#!/bin/bash
# Step 11: Summary
# Displays startup summary and next steps

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[11/11] Startup Summary"
echo "==================="
echo "Cluster Name: Talos Cluster"
echo "Network: $NETWORK_NAME"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes (starting at $WORKER_IP_BASE)"
echo ""
echo "Boot Status:"
echo "  ✓ VMs booted from ISO (initial install)"
echo "  ✓ ISO ejected"
echo "  ✓ VMs rebooted from disk"
echo ""
echo "Next steps:"
echo "  1. Generate machine configurations:"
echo "     talosctl gen config ${CLUSTER_NAME:-talos-default} https://$MASTER_IP:6443"
echo "  2. Apply configurations with talosctl"
echo "     ./scripts/talos-bootstrap.sh"
echo ""
echo "=== VM Startup Complete ==="
