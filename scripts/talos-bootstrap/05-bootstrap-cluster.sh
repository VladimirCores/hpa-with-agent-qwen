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

# Talos v1.12.x: Use version command to detect maintenance mode
# In maintenance mode: "API is not implemented in maintenance mode"
# In cluster mode: Returns actual version info
# Use explicit --endpoints since talosconfig may have empty endpoints
# Note: talosctl returns non-zero in maintenance mode, so use || true
VERSION_OUTPUT=$(talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --insecure 2>&1 || true)

if echo "$VERSION_OUTPUT" | grep -q "API is not implemented in maintenance mode"; then
    echo "  ✓ Node is in maintenance mode (Talos v1.12.x)"
    echo "  Applying config before bootstrap..."
    talosctl apply-config --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --insecure --file "$CONFIG_DIR/controlplane.yaml" 2>&1 || true
    echo "  Waiting for node to reboot after config apply..."
    sleep 30
    # Fix endpoints in talosconfig
    sed -i 's/endpoints: \[\]/endpoints: ['$MASTER_IP']/g' "$CONFIG_DIR/talosconfig"
    # Wait for node to come back up
    for i in $(seq 1 20); do
        if talosctl version --nodes "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep -q "Server:"; then
            echo "  ✓ Node is back online"
            break
        fi
        echo "  Waiting for node... (${i}s)"
        sleep 3
    done
elif echo "$VERSION_OUTPUT" | grep -q "PermissionDenied"; then
    echo "  ✓ Node is in cluster mode but not bootstrapped"
    echo "  Attempting bootstrap..."
else
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
    # VM prefix is dynamic based on project directory
    VM_PREFIX="$(basename "$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")")_"
    echo "    virsh -c qemu:///system vol-delete --pool $STORAGE_POOL ${VM_PREFIX}talos-master-vda.qcow2"
    for i in $(seq 1 $WORKER_COUNT); do
        echo "    virsh -c qemu:///system vol-delete --pool $STORAGE_POOL ${VM_PREFIX}talos-worker-${i}-vda.qcow2"
    done
    echo ""
    exit 1
fi

# Perform bootstrap
echo "  Bootstrapping cluster on $MASTER_NAME ($MASTER_IP)..."

# Bootstrap with explicit endpoints (no --insecure flag for bootstrap in v1.12)
if talosctl bootstrap --nodes "$MASTER_IP" --endpoints "$MASTER_IP" 2>&1; then
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
