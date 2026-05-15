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

# Function to reset node to maintenance mode
reset_worker_to_maintenance() {
    local node_ip="$1"
    local node_name="$2"
    
    echo "  Resetting $node_name ($node_ip) to maintenance mode..."
    
    # Try graceful reset first
    if talosctl reset --nodes "$node_ip" --endpoints "$node_ip" --insecure --graceful=false --wait=false 2>&1; then
        echo "  ✓ Reset command sent successfully"
        echo "  Waiting for node to enter maintenance mode..."
        sleep 15
        
        # Wait for node to be accessible in maintenance mode
        for i in $(seq 1 30); do
            local reset_check=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1 || true)
            if echo "$reset_check" | grep -q "Tag:"; then
                echo "  ✓ Node is in maintenance mode (${i}s)"
                return 0
            fi
            if [[ $((i % 5)) -eq 0 ]]; then
                echo "  ... waiting for reset (${i}s)"
            fi
            sleep 3
        done
        echo "  WARNING: Node may not have fully reset"
        return 1
    else
        echo "  ERROR: Failed to reset node"
        return 1
    fi
}

# Function to check worker state and apply config
apply_worker_config() {
    local node_ip="$1"
    local node_name="$2"
    
    echo "  Checking $node_name ($node_ip) state..."
    
    # Try with insecure flag first (for nodes in maintenance mode)
    local version_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1 || true)
    
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
        echo "  Node has TLS errors, attempting with secure connection..."
        
        if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
            echo "  ✓ Worker config applied"
            return 0
        else
            echo "  WARNING: Config apply failed, attempting reset..."
            
            if reset_worker_to_maintenance "$node_ip" "$node_name"; then
                echo "  Retrying config apply after reset..."
                if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
                    echo "  ✓ Worker config applied after reset"
                    return 0
                else
                    echo "  ERROR: Config apply failed even after reset"
                    return 1
                fi
            else
                echo "  ERROR: Could not reset node"
                return 1
            fi
        fi
        
    else
        echo "  WARNING: Unexpected response from node"
        echo "  Response: $(echo "$version_output" | head -5)"
        echo "  Attempting to reset node and apply configuration..."
        
        if reset_worker_to_maintenance "$node_ip" "$node_name"; then
            echo "  Applying config after reset..."
            if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
                echo "  ✓ Worker config applied successfully after reset"
                return 0
            else
                echo "  ERROR: Failed to apply config after reset"
                return 1
            fi
        else
            echo "  ERROR: Failed to reset node"
            return 1
        fi
    fi
}

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
    
    APPLY_SUCCESS=false
    for attempt in 1 2 3; do
        if apply_worker_config "$WORKER_IP" "$WORKER_NAME"; then
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
        echo "  ERROR: Could not apply config to $WORKER_NAME"
        echo "  Manual intervention may be required"
        echo "  Try: talosctl reset --nodes $WORKER_IP --endpoints $WORKER_IP --insecure --graceful=false --wait=false"
        echo "  Then re-run this script"
        exit 1
    fi
    
    echo ""
done

echo "  ✓ Machine configuration phase complete"
echo ""
