#!/bin/bash
# =============================================================================
# Step 05: Bootstrap Kubernetes Cluster
# =============================================================================
# Bootstraps the Kubernetes cluster on the control plane node.
# IMPORTANT: Must be done BEFORE apply-config and node must be in maintenance mode.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[5/9] Bootstrapping Kubernetes cluster..."

# Verify config files exist
if [[ ! -f "$CONFIG_DIR/talosconfig" ]]; then
    echo "  ERROR: talosconfig not found: $CONFIG_DIR/talosconfig"
    echo "  Run step 03 first: ./scripts/talos-bootstrap/03-generate-configs.sh"
    exit 1
fi

# Check if node is in maintenance mode
echo "  Checking node maintenance mode..."
MACHINECONFIG_OUTPUT=$(talosctl get machineconfig --nodes "$MASTER_IP" --insecure 2>&1)

if echo "$MACHINECONFIG_OUTPUT" | grep -q "PermissionDenied"; then
    echo "  ERROR: Node is NOT in maintenance mode"
    echo ""
    echo "  Talos v1.12.x requires EMPTY disk to boot into maintenance mode."
    echo "  The disk has existing Talos state."
    echo ""
    echo "  Solution: Run full cleanup to wipe disks:"
    echo "    ./scripts/vms-cleanup.sh"
    echo "    ./scripts/vms-startup.sh"
    echo "    ./scripts/talos-bootstrap.sh"
    echo ""
    echo "  Or manually wipe disks:"
    echo "    virsh -c qemu:///system vol-delete --pool $STORAGE_POOL with-agent-qwen_talos-master-vda.qcow2"
    for i in $(seq 1 $WORKER_COUNT); do
        echo "    virsh -c qemu:///system vol-delete --pool $STORAGE_POOL with-agent-qwen_talos-worker-${i}-vda.qcow2"
    done
    echo ""
    exit 1
fi

# Perform bootstrap
echo "  Bootstrapping cluster on $MASTER_NAME ($MASTER_IP)..."

if talosctl bootstrap --nodes "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig"; then
    echo "  ✓ Kubernetes cluster bootstrapped"
else
    echo "  ERROR: Bootstrap failed"
    echo ""
    echo "  Troubleshooting:"
    echo "  1. Ensure VMs are booted from ISO with EMPTY disks"
    echo "  2. Check Talos is accessible: talosctl get version --nodes $MASTER_IP --insecure"
    echo "  3. Check maintenance mode: talosctl get machineconfig --nodes $MASTER_IP --insecure"
    echo "     - Empty output or success = maintenance mode ✓"
    echo "     - PermissionDenied = cluster mode (wipe disks)"
    echo ""
    exit 1
fi

echo ""
echo "  ✓ Bootstrap complete"
echo ""
