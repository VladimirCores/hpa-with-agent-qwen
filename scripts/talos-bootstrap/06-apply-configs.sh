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

    local version_output
    version_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1 || true)

    if echo "$version_output" | grep -q "Tag:"; then
        echo "  ✓ Node is in maintenance mode"

        if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
            echo "  ✓ Worker config applied"
            return 0
        else
            echo "  ERROR: Failed to apply config"
            return 1
        fi

    elif echo "$version_output" | grep -q "certificate signed by unknown authority"; then
        echo "  Node has TLS errors (may already be configured)"
        echo "  Attempting config apply with --insecure anyway..."

        if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
            echo "  ✓ Worker config applied"
            return 0
        else
            echo "  WARNING: Config apply failed. Node might already have config applied."
            echo "  Skipping for now."
            return 0
        fi

    else
        echo "  WARNING: Unexpected response from node"
        echo "  Response: $(echo "$version_output" | head -3)"
        echo "  Attempting config apply anyway..."
        talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1 || true
        return 0
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
