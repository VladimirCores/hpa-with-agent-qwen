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
    sleep 60
    # Fix endpoints in talosconfig
    sed -i 's/endpoints: \[\]/endpoints: ['$MASTER_IP']/g' "$CONFIG_DIR/talosconfig"
    # Wait for node to come back up with new PKI
    echo "  Waiting for node to come back online..."
    for i in $(seq 1 40); do
        local_output=$(talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
        if echo "$local_output" | grep -q "Server:"; then
            echo "  ✓ Node is back online (${i}s)"
            break
        fi
        if [[ $((i % 10)) -eq 0 ]]; then
            echo "  ... waiting for node (${i}s)"
        fi
        sleep 3
    done
elif echo "$VERSION_OUTPUT" | grep -q "Tag:" && echo "$VERSION_OUTPUT" | grep -q "Server:" && ! echo "$VERSION_OUTPUT" | grep -q "not implemented"; then
    echo "  ✓ Node is in cluster mode (already configured)"
    echo "  Checking if cluster is already bootstrapped..."
    
    # Wait for node to be fully ready after reboot
    echo "  Waiting for node to be fully initialized..."
    for i in $(seq 1 20); do
        if talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep -q "Member"; then
            echo "  ✓ Node is fully initialized (${i}s)"
            break
        fi
        if [[ $((i % 5)) -eq 0 ]]; then
            echo "  ... waiting for cluster membership (${i}s)"
        fi
        sleep 3
    done
    
    # Check if cluster is already bootstrapped
    if talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep -q "Member"; then
        echo "  ✓ Cluster is already bootstrapped"
        echo "  Skipping bootstrap, continuing to apply configs..."
    else
        echo "  WARNING: Cluster members not accessible"
        echo "  Attempting bootstrap anyway..."
    fi
else
    echo "  WARNING: Unexpected response from node"
    echo "  Response: $(echo "$VERSION_OUTPUT" | head -5)"
    echo "  Proceeding anyway..."
fi

# Perform bootstrap
echo "  Bootstrapping cluster on $MASTER_NAME ($MASTER_IP)..."

# Try bootstrap with retries (node may need time to fully initialize after reboot)
BOOTSTRAP_SUCCESS=false
for attempt in 1 2 3 4 5; do
    echo "  Bootstrap attempt $attempt..."
    if talosctl bootstrap --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
        echo "  ✓ Kubernetes cluster bootstrapped"
        BOOTSTRAP_SUCCESS=true
        break
    else
        echo "  Attempt $attempt failed"
        if [[ $attempt -lt 5 ]]; then
            echo "  Waiting 30s before retry..."
            sleep 30
        fi
    fi
done

if [[ "$BOOTSTRAP_SUCCESS" != "true" ]]; then
    echo "  WARNING: Bootstrap command failed"
    echo "  Checking if cluster is already bootstrapped..."
    
    # Wait for node to be fully ready after reboot/transition
    echo "  Waiting for cluster to stabilize..."
    for i in $(seq 1 30); do
        check_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
        if echo "$check_output" | grep -q "Member"; then
            echo "  ✓ Cluster is stable (${i}s)"
            break
        fi
        if [[ $((i % 5)) -eq 0 ]]; then
            echo "  ... waiting for cluster stability (${i}s)"
        fi
        sleep 3
    done
    
    # Final check
    check_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    if echo "$check_output" | grep -q "Member"; then
        echo "  ✓ Cluster is already bootstrapped"
        echo "  Skipping bootstrap, continuing to apply configs..."
    else
        echo "  WARNING: Bootstrap failed and cluster membership not detected"
        echo "  This may be normal if node is still initializing"
        echo "  Continuing to apply configs anyway..."
    fi
fi

# Verify all nodes are healthy after bootstrap
echo ""
echo "  Verifying node health..."
echo "  Checking Talos cluster members..."

EXPECTED_NODES=$((1 + WORKER_COUNT))
NODE_CHECK_WAIT=0
NODE_CHECK_INTERVAL=5
NODE_CHECK_TIMEOUT=120

while [[ $NODE_CHECK_WAIT -lt $NODE_CHECK_TIMEOUT ]]; do
    MEMBERS_OUTPUT=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    MEMBER_COUNT=$(echo "$MEMBERS_OUTPUT" | grep -c "Member" || echo "0")
    
    if [[ $MEMBER_COUNT -ge $EXPECTED_NODES ]]; then
        echo "  ✓ All $EXPECTED_NODES nodes present in cluster (${NODE_CHECK_WAIT}s)"
        echo ""
        echo "  Cluster members:"
        echo "$MEMBERS_OUTPUT" | grep "Member" | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi
    
    if [[ $((NODE_CHECK_WAIT % 15)) -eq 0 ]] || [[ $NODE_CHECK_WAIT -lt 30 ]]; then
        echo "    Found $MEMBER_COUNT/$EXPECTED_NODES nodes... (${NODE_CHECK_WAIT}s)"
    fi
    
    sleep $NODE_CHECK_INTERVAL
    NODE_CHECK_WAIT=$((NODE_CHECK_WAIT + NODE_CHECK_INTERVAL))
done

if [[ $NODE_CHECK_WAIT -ge $NODE_CHECK_TIMEOUT ]]; then
    echo "  WARNING: Only $MEMBER_COUNT/$EXPECTED_NODES nodes found after ${NODE_CHECK_TIMEOUT}s"
    echo "  Workers may still be joining the cluster"
fi

# Verify etcd health
echo ""
echo "  Checking etcd health..."
ETCD_WAIT=0
ETCD_TIMEOUT=60

while [[ $ETCD_WAIT -lt $ETCD_TIMEOUT ]]; do
    ETCD_OUTPUT=$(talosctl get etcdmembers --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    ETCD_MEMBER_COUNT=$(echo "$ETCD_OUTPUT" | grep -c "EtcdMember" || echo "0")
    
    if [[ $ETCD_MEMBER_COUNT -ge 1 ]]; then
        echo "  ✓ etcd is healthy (${ETCD_WAIT}s)"
        break
    fi
    
    if [[ $((ETCD_WAIT % 10)) -eq 0 ]]; then
        echo "    Waiting for etcd... (${ETCD_WAIT}s)"
    fi
    
    sleep 5
    ETCD_WAIT=$((ETCD_WAIT + 5))
done

if [[ $ETCD_WAIT -ge $ETCD_TIMEOUT ]]; then
    echo "  WARNING: etcd may not be fully healthy"
fi

echo ""
echo "  ✓ Bootstrap phase complete"
echo ""
