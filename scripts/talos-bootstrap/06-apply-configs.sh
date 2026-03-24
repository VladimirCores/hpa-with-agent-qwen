#!/bin/bash
# =============================================================================
# Step 06: Apply Talos Configurations
# =============================================================================
# Applies the control plane and worker configurations to all nodes.
# Uses --insecure flag for pre-reboot connection.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[6/9] Applying Talos configurations..."

# Verify config files exist
if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ERROR: Configuration files not found"
    echo "  Run step 03 first: ./scripts/talos-bootstrap/03-generate-configs.sh"
    exit 1
fi

# Apply to control plane
echo "  Applying controlplane config to $MASTER_NAME ($MASTER_IP)..."
if talosctl apply-config --nodes "$MASTER_IP" --file "$CONFIG_DIR/controlplane.yaml" --insecure; then
    echo "  ✓ Controlplane config applied"
else
    echo "  ERROR: Failed to apply controlplane config"
    exit 1
fi

# Apply to workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    if talosctl apply-config --nodes "$WORKER_IP" --file "$CONFIG_DIR/worker.yaml" --insecure; then
        echo "  ✓ Worker config applied to $WORKER_NAME"
    else
        echo "  ERROR: Failed to apply worker config to $WORKER_NAME"
        exit 1
    fi
done

echo ""
echo "  ✓ All configurations applied"
echo "  Note: Nodes will reboot to apply new configuration"
echo ""
