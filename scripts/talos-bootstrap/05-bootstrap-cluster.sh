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

# Function to check node state and ensure proper configuration
ensure_node_configured() {
    local node_ip="$1"
    local node_type="$2"
    local config_file="$3"
    
    echo "  Checking node $node_ip ($node_type) state..."
    
    # Try secure connection first
    SECURE_OUTPUT=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    
    if echo "$SECURE_OUTPUT" | grep -q "certificate signed by unknown authority"; then
        echo "  ✓ Node is in maintenance mode (Talos v1.13+)"
        echo "  Applying config before bootstrap..."
        
        if ! talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$config_file" 2>&1; then
            echo "  ERROR: Failed to apply machine configuration"
            echo "  Attempting to reset node to maintenance mode..."
            
            if reset_to_maintenance "$node_ip"; then
                echo "  Retrying config apply after reset..."
                if ! talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$config_file" 2>&1; then
                    echo "  ERROR: Config apply failed even after reset"
                    return 1
                fi
            else
                echo "  ERROR: Could not reset node"
                return 1
            fi
        fi
        
        echo "  Rebooting node to reload containerd with registry mirrors..."
        talosctl reboot --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" --wait=false 2>&1 || true
        sleep 5
        echo "  Waiting for node to reboot after config apply..."
        sleep 10
        
        # Fix endpoints in talosconfig
        sed -i 's/endpoints: \[\]/endpoints: ['"$node_ip"']/g' "$CONFIG_DIR/talosconfig" 2>/dev/null || true
        
        # Wait for node to come back up with new PKI
        echo "  Waiting for node to come back online..."
        for i in $(seq 1 40); do
            local_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
            if echo "$local_output" | grep -q "Server:" && ! echo "$local_output" | grep -q "certificate signed by unknown authority"; then
                echo "  ✓ Node is back online (${i}s)"
                return 0
            fi
            if [[ $((i % 10)) -eq 0 ]]; then
                echo "  ... waiting for node (${i}s)"
            fi
            sleep 3
        done
        echo "  WARNING: Node may not be fully online yet"
        return 0
        
    elif echo "$SECURE_OUTPUT" | grep -q "Tag:" && echo "$SECURE_OUTPUT" | grep -q "Server:"; then
        echo "  ✓ Node is in cluster mode (already configured)"
        return 0
        
    else
        echo "  WARNING: Unexpected response from node"
        echo "  Response: $(echo "$SECURE_OUTPUT" | head -5)"
        echo "  Attempting to reset node and apply configuration..."
        
        # For unexpected responses, reset and apply config
        if reset_to_maintenance "$node_ip"; then
            echo "  Applying config after reset..."
            if talosctl apply-config --nodes "$node_ip" --endpoints "$node_ip" --insecure --file "$config_file" 2>&1; then
                echo "  ✓ Config applied successfully after reset"
                
                echo "  Rebooting node..."
                talosctl reboot --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" --wait=false 2>&1 || true
                sleep 5
                sleep 10
                
                # Fix endpoints in talosconfig
                sed -i 's/endpoints: \[\]/endpoints: ['"$node_ip"']/g' "$CONFIG_DIR/talosconfig" 2>/dev/null || true
                
                echo "  Waiting for node to come back online..."
                for i in $(seq 1 40); do
                    local_output=$(talosctl version --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
                    if echo "$local_output" | grep -q "Server:" && ! echo "$local_output" | grep -q "certificate signed by unknown authority"; then
                        echo "  ✓ Node is back online (${i}s)"
                        return 0
                    fi
                    if [[ $((i % 10)) -eq 0 ]]; then
                        echo "  ... waiting for node (${i}s)"
                    fi
                    sleep 3
                done
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

# Check if node is in maintenance mode and ensure proper configuration
echo "  Checking node maintenance mode..."
if ! ensure_node_configured "$MASTER_IP" "controlplane" "$CONFIG_DIR/controlplane.yaml"; then
    echo "  ERROR: Failed to configure master node"
    echo "  Manual intervention may be required"
    exit 1
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
        echo "  ERROR: Bootstrap failed and cluster membership not detected"
        echo "  This indicates a critical failure in the bootstrap process"
        echo ""
        echo "  ═══════════════════════════════════════════════════════════"
        echo "  DIAGNOSTIC INFORMATION"
        echo "  ═══════════════════════════════════════════════════════════"
        echo ""
        echo "  Last talosctl get members output:"
        echo "  $check_output"
        echo ""

        # Check node version/state
        echo "  Checking node state..."
        version_output=$(talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
        echo "  Node version response:"
        echo "  $version_output"
        echo ""

        # Check if node is reachable
        echo "  Testing connectivity..."
        ping_result=$(ping -c 2 "$MASTER_IP" 2>&1 | tail -2 || true)
        echo "  Ping result: $ping_result"
        echo ""

        # Check machine config status
        echo "  Checking machine configuration..."
        config_output=$(talosctl get machineconfig --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
        echo "  Machine config response:"
        echo "  $config_output"
        echo ""

        # Check services status
        echo "  Checking critical services..."
        services_output=$(talosctl services --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep -E "(etcd|trustd|machined)" || true)
        echo "  Critical services status:"
        echo "  $services_output"
        echo ""

        echo "  ═══════════════════════════════════════════════════════════"
        echo "  COMMON CAUSES AND SOLUTIONS"
        echo "  ═══════════════════════════════════════════════════════════"
        echo ""
        echo "  1. VM booted from ISO instead of hard disk:"
        echo "     - Check VM boot order (disk should be first, CDROM second)"
        echo "     - Verify VM is not stuck in maintenance mode"
        echo ""
        echo "  2. Network connectivity issues:"
        echo "     - Verify MASTER_IP ($MASTER_IP) is correct"
        echo "     - Check firewall rules allow Talos ports (50000, 50001)"
        echo ""
        echo "  3. Configuration problems:"
        echo "     - Ensure controlplane.yaml was generated correctly"
        echo "     - Check if apply-config succeeded before bootstrap"
        echo ""
        echo "  4. Insufficient resources:"
        echo "     - Verify VM has enough CPU/RAM for Talos + Kubernetes"
        echo "     - Minimum: 2 CPU, 2GB RAM for control plane"
        echo ""
        echo "  Manual intervention required"
        echo "  Review logs above and check VM console output"
        exit 1
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
    MEMBER_COUNT=$(echo "$MEMBERS_OUTPUT" | grep -c "Member" 2>/dev/null || echo "0")
    MEMBER_COUNT=$(echo "$MEMBER_COUNT" | tr -d '[:space:]')

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
    ETCD_MEMBER_COUNT=$(echo "$ETCD_OUTPUT" | grep -c "EtcdMember" 2>/dev/null || echo "0")
    ETCD_MEMBER_COUNT=$(echo "$ETCD_MEMBER_COUNT" | tr -d '[:space:]')

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
