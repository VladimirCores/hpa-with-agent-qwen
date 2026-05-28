#!/bin/bash
# =============================================================================
# Step 06: Apply Worker Machine Configurations
# =============================================================================
# Applies worker machine configurations.
# Controlplane config was already applied in step 05.
# Can be run independently to (re)apply worker configs.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[6/9] Applying worker configurations..."
echo "  Workers: $WORKER_COUNT nodes ($WORKER_IP_BASE)"
echo ""

# Verify config files exist
if [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ERROR: worker.yaml not found: $CONFIG_DIR/worker.yaml"
    echo "  Run step 03 first: ./scripts/talos-bootstrap/03-generate-configs.sh"
    exit 1
fi

# Function to check worker node and apply config
apply_worker_config() {
    local node_ip="$1"
    local node_name="$2"

    echo "  Checking $node_name ($node_ip) state..."

    # First check if node is in maintenance mode (no config applied)
    local MAINTENANCE=false
    if version_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1); then
        if echo "$version_output" | grep -q "Tag:"; then
            MAINTENANCE=true
            echo "  ✓ Node is in maintenance mode"
        fi
    fi

    if [[ "$MAINTENANCE" == "true" ]]; then
        # Apply config via maintenance mode API
        if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
            echo "  ✓ Worker config applied"
            return 0
        else
            echo "  ERROR: Failed to apply config"
            return 1
        fi
    else
        # Node is already configured (RBAC enabled, requires talosconfig)
        echo "  Node $node_name is already configured (not in maintenance mode)"
        echo "  Skipping config apply (config was already applied previously)"

        # Verify connectivity via talosconfig
        if talosctl version --nodes "$node_ip" --endpoints "$MASTER_IP" --talosconfig "$TALOSCONFIG" 2>&1 | grep -q "Tag:"; then
            echo "  ✓ Talos API accessible via talosconfig"
            return 0
        else
            echo "  WARNING: Could not verify Talos API connectivity"
            return 0
        fi
    fi
}

# Apply worker configs with retry logic
ALL_OK=true
for i in $(seq 1 "$WORKER_COUNT"); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')

    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."

    APPLY_SUCCESS=false
    for attempt in 1 2 3; do
        if apply_worker_config "$WORKER_IP" "$WORKER_NAME"; then
            echo "  ✓ $WORKER_NAME done (attempt $attempt)"
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
        echo "  ERROR: Could not apply config to $WORKER_NAME"
        echo "  Try: talosctl reset --nodes $WORKER_IP --endpoints $WORKER_IP --insecure --graceful=false"
        echo "  Then re-run this script"
        ALL_OK=false
    fi

    echo ""
done

if [[ "$ALL_OK" != "true" ]]; then
    echo "  WARNING: Some workers may not have been configured successfully"
    exit 1
fi

echo "  ✓ Worker configuration phase complete"
echo ""
