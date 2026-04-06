#!/bin/bash
# =============================================================================
# Step 06: Apply Machine Configurations
# =============================================================================
# Applies machine configurations to all nodes.
# Must be done AFTER bootstrap and nodes must be accessible.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[6/9] Applying machine configurations..."
echo ""

# Verify config files exist
if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ERROR: Configuration files not found"
    echo "  Run step 03 first: ./scripts/talos-bootstrap/03-generate-configs.sh"
    exit 1
fi

# Apply controlplane config
echo "  Applying controlplane config to $MASTER_NAME ($MASTER_IP)..."
if talosctl apply-config --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --file "$CONFIG_DIR/controlplane.yaml" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
    echo "  ✓ Controlplane config applied"
else
    echo "  ✗ Failed to apply controlplane config"
    exit 1
fi

echo ""

# Apply worker configs
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    if talosctl apply-config --nodes "$WORKER_IP" --endpoints "$WORKER_IP" --file "$CONFIG_DIR/worker.yaml" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
        echo "  ✓ $WORKER_NAME config applied"
    else
        echo "  ✗ Failed to apply $WORKER_NAME config"
        exit 1
    fi
    echo ""
done

echo "  ✓ All machine configurations applied"
echo ""
