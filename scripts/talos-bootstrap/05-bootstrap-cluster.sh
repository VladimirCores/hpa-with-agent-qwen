#!/bin/bash
# =============================================================================
# Step 05: Bootstrap Kubernetes Cluster
# =============================================================================
# Bootstraps the Kubernetes cluster on the control plane node.
# CRITICAL: Bootstrap must happen BEFORE any reboot that would regenerate certs.
# The node should be in maintenance mode with insecure access.
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

# Function to check if node is in maintenance mode (insecure access works)
check_maintenance_mode() {
    local node_ip="$1"
    
    # Try insecure connection - this only works in maintenance mode
    local version_output
    version_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1 || true)
    
    if echo "$version_output" | grep -q "Tag:"; then
        return 0  # In maintenance mode
    elif echo "$version_output" | grep -q "certificate signed by unknown authority"; then
        return 1  # Has certs but not trusted (already configured)
    else
        return 2  # Unknown state or unreachable
    fi
}

# Function to reset node to maintenance mode
reset_to_maintenance() {
    local node_ip="$1"
    echo "  Resetting node $node_ip to maintenance mode..."
    
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

# Ensure node is in maintenance mode and ready for bootstrap
ensure_node_ready_for_bootstrap() {
    local node_ip="$1"
    
    echo "  Checking node $node_ip state..."
    
    check_maintenance_mode "$node_ip"
    local state=$?
    
    if [[ $state -eq 0 ]]; then
        echo "  ✓ Node is in maintenance mode (ready for bootstrap)"
        return 0
    elif [[ $state -eq 1 ]]; then
        echo "  Node appears to have certificates (may be already configured)"
        echo "  Attempting to reset to maintenance mode..."
        
        if reset_to_maintenance "$node_ip"; then
            echo "  ✓ Node reset to maintenance mode"
            return 0
        else
            echo "  ERROR: Failed to reset node"
            return 1
        fi
    else
        echo "  Node state unclear, attempting reset..."
        
        if reset_to_maintenance "$node_ip"; then
            return 0
        else
            echo "  ERROR: Cannot reach node"
            return 1
        fi
    fi
}

# Check if cluster is already bootstrapped
check_if_bootstrapped() {
    local node_ip="$1"
    
    # Try with talosconfig first
    local members_output
    members_output=$(talosctl get members --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    
    if echo "$members_output" | grep -q "Member"; then
        return 0  # Already bootstrapped
    fi
    
    # Try insecure (maintenance mode)
    members_output=$(talosctl get members --nodes "$node_ip" --endpoints "$node_ip" --insecure 2>&1 || true)
    
    if echo "$members_output" | grep -q "Member"; then
        return 0  # Already bootstrapped
    fi
    
    return 1  # Not bootstrapped
}

# Main bootstrap logic
echo "  Ensuring node is ready for bootstrap..."
if ! ensure_node_ready_for_bootstrap "$MASTER_IP"; then
    echo "  ERROR: Node is not ready for bootstrap"
    echo "  Manual intervention may be required"
    exit 1
fi

# Check if already bootstrapped
if check_if_bootstrapped "$MASTER_IP"; then
    echo "  ✓ Cluster is already bootstrapped"
    echo "  Skipping bootstrap, continuing..."
    echo ""
    echo "  Verifying cluster health..."
else
    # Perform bootstrap using maintenance mode
    # In Talos v1.13+, maintenance mode uses self-signed certs that talosctl can auto-accept
    echo "  Bootstrapping cluster on $MASTER_NAME ($MASTER_IP)..."
    echo "  Node is in maintenance mode..."
    
    BOOTSTRAP_SUCCESS=false
    for attempt in 1 2 3 4 5; do
        echo "  Bootstrap attempt $attempt..."
        
        # In maintenance mode, talosctl will auto-accept the self-signed certificate
        # Use --insecure flag to accept self-signed certs during bootstrap
        if TALOSCONFIG="$CONFIG_DIR/talosconfig" talosctl bootstrap --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --insecure 2>&1; then
            echo "  ✓ Kubernetes cluster bootstrapped"
            BOOTSTRAP_SUCCESS=true
            break
        else
            echo "  Attempt $attempt failed"
            if [[ $attempt -lt 5 ]]; then
                echo "  Waiting 15s before retry..."
                sleep 15
            fi
        fi
    done
    
    if [[ "$BOOTSTRAP_SUCCESS" != "true" ]]; then
        echo "  ERROR: Bootstrap failed after all attempts"
        echo ""
        echo "  ═══════════════════════════════════════════════════════════"
        echo "  TROUBLESHOOTING"
        echo "  ═══════════════════════════════════════════════════════════"
        echo ""
        echo "  1. Check VM console output for errors"
        echo "  2. Verify VM booted from hard disk (not ISO)"
        echo "  3. Check VM boot order: disk first, CDROM second"
        echo "  4. Verify network connectivity:"
        echo "     ping -c 3 $MASTER_IP"
        echo "  5. Try manual reset:"
        echo "     talosctl reset --nodes $MASTER_IP --endpoints $MASTER_IP --insecure --graceful=false"
        echo ""
        exit 1
    fi
    
    echo ""
    echo "  Waiting for cluster to initialize..."
    sleep 10
fi

# Update talosconfig with correct endpoint
echo "  Updating talosconfig with endpoint..."
sed -i 's/endpoints: \[\]/endpoints: ["'"$MASTER_IP"'"]/g' "$CONFIG_DIR/talosconfig" 2>/dev/null || true
sed -i "s|endpoints: \[.*\]|endpoints: [\"$MASTER_IP\"]|g" "$CONFIG_DIR/talosconfig" 2>/dev/null || true

# Wait for cluster to stabilize and verify with talosconfig
echo "  Waiting for cluster to stabilize..."
STABILIZE_WAIT=0
STABILIZE_TIMEOUT=120

while [[ $STABILIZE_WAIT -lt $STABILIZE_TIMEOUT ]]; do
    members_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    
    if echo "$members_output" | grep -q "Member"; then
        echo "  ✓ Cluster is stable (${STABILIZE_WAIT}s)"
        echo ""
        echo "  Cluster members:"
        echo "$members_output" | grep "Member" | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi
    
    if [[ $((STABILIZE_WAIT % 15)) -eq 0 ]]; then
        echo "    Waiting for cluster... (${STABILIZE_WAIT}s)"
    fi
    
    sleep 5
    STABILIZE_WAIT=$((STABILIZE_WAIT + 5))
done

if [[ $STABILIZE_WAIT -ge $STABILIZE_TIMEOUT ]]; then
    echo "  WARNING: Cluster may not be fully stable"
    echo "  Last output: $members_output"
fi

# Verify etcd health
echo ""
echo "  Checking etcd health..."
ETCD_WAIT=0
ETCD_TIMEOUT=60

while [[ $ETCD_WAIT -lt $ETCD_TIMEOUT ]]; do
    etcd_output=$(talosctl get etcdmembers --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    etcd_count=$(echo "$etcd_output" | grep -c "EtcdMember" 2>/dev/null || echo "0")
    etcd_count=$(echo "$etcd_count" | tr -d '[:space:]')
    
    if [[ $etcd_count -ge 1 ]]; then
        echo "  ✓ etcd is healthy (${ETCD_WAIT}s)"
        break
    fi
    
    if [[ $((ETCD_WAIT % 10)) -eq 0 ]]; then
        echo "    Waiting for etcd... (${ETCD_WAIT}s)"
    fi
    
    sleep 5
    ETCD_WAIT=$((ETCD_WAIT + 5))
done

# Verify all nodes are healthy after bootstrap
echo ""
echo "  Verifying node health..."
echo "  Checking Talos cluster members..."

EXPECTED_NODES=$((1 + WORKER_COUNT))
NODE_CHECK_WAIT=0
NODE_CHECK_INTERVAL=5
NODE_CHECK_TIMEOUT=120

while [[ $NODE_CHECK_WAIT -lt $NODE_CHECK_TIMEOUT ]]; do
    members_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    member_count=$(echo "$members_output" | grep -c "Member" 2>/dev/null || echo "0")
    member_count=$(echo "$member_count" | tr -d '[:space:]')
    
    if [[ $member_count -ge $EXPECTED_NODES ]]; then
        echo "  ✓ All $EXPECTED_NODES nodes present in cluster (${NODE_CHECK_WAIT}s)"
        echo ""
        echo "  Cluster members:"
        echo "$members_output" | grep "Member" | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi
    
    if [[ $((NODE_CHECK_WAIT % 15)) -eq 0 ]] || [[ $NODE_CHECK_WAIT -lt 30 ]]; then
        echo "    Found $member_count/$EXPECTED_NODES nodes... (${NODE_CHECK_WAIT}s)"
    fi
    
    sleep $NODE_CHECK_INTERVAL
    NODE_CHECK_WAIT=$((NODE_CHECK_WAIT + NODE_CHECK_INTERVAL))
done

if [[ $NODE_CHECK_WAIT -ge $NODE_CHECK_TIMEOUT ]]; then
    echo "  WARNING: Only $member_count/$EXPECTED_NODES nodes found after ${NODE_CHECK_TIMEOUT}s"
    echo "  Workers may still be joining the cluster"
fi

if [[ $ETCD_WAIT -ge $ETCD_TIMEOUT ]]; then
    echo "  WARNING: etcd may not be fully healthy"
fi

echo ""
echo "  ✓ Bootstrap phase complete"
echo ""
