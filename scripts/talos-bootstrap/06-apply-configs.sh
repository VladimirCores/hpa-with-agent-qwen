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
echo "  Master: $MASTER_NAME ($MASTER_IP)"
echo "  Workers: $WORKER_COUNT nodes ($WORKER_IP_BASE)"
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
    echo "  WARNING: Controlplane config apply returned non-zero"
    echo "  (This may be normal if node is already configured)"
fi

echo ""

# Apply worker configs with retry logic
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    
    # Try with insecure flag first (for nodes in maintenance mode)
    APPLY_SUCCESS=false
    for attempt in 1 2 3; do
        if talosctl apply-config --nodes "$WORKER_IP" --endpoints "$WORKER_IP" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
            echo "  ✓ $WORKER_NAME config applied (attempt $attempt)"
            APPLY_SUCCESS=true
            break
        else
            echo "  Attempt $attempt failed for $WORKER_NAME"
            if [[ $attempt -lt 3 ]]; then
                echo "  Waiting 10s before retry..."
                sleep 10
            fi
        fi
    done
    
    if [[ "$APPLY_SUCCESS" != "true" ]]; then
        echo "  WARNING: Could not apply config to $WORKER_NAME"
        echo "  Worker may need to be reset to maintenance mode first"
        echo "  Command: talosctl reset --nodes $WORKER_IP --endpoints $WORKER_IP --insecure --graceful=false --wait=false"
    fi
    
    echo ""
done

echo "  ✓ Machine configuration phase complete"
echo ""
