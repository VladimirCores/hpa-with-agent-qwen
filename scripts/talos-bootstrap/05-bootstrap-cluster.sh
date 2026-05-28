#!/bin/bash
# =============================================================================
# Step 05: Bootstrap Kubernetes Cluster
# =============================================================================
# Talos v1.13+ bootstrap workflow:
#   1. Apply controlplane config (node in maintenance mode, uses --insecure)
#   2. Node reboots automatically after config is applied
#   3. Bootstrap (node is now configured, uses talosconfig, NO --insecure)
#   4. Apply worker configs
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

# ──────────────────────────────────────────────
# Phase 1: Detect node state and apply/verify config
# ──────────────────────────────────────────────
echo ""
echo "  ── Phase 1: Check node state ──"

# Check if node is in maintenance mode (no config applied yet)
NODE_IN_MAINTENANCE=false
if version_output=$(talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --insecure 2>&1); then
    if echo "$version_output" | grep -q "Tag:"; then
        NODE_IN_MAINTENANCE=true
        echo "  Node $MASTER_NAME ($MASTER_IP) is in maintenance mode"
    fi
fi

if [[ "$NODE_IN_MAINTENANCE" == "true" ]]; then
    # ── Apply config via maintenance mode API (--insecure) ──
    echo ""
    echo "  ── Phase 1a: Apply controlplane config ──"
    echo "  Applying controlplane config..."

    APPLY_SUCCESS=false
    for attempt in 1 2 3; do
        echo "  Config apply attempt $attempt..."
        if talosctl apply-config --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --insecure --file "$CONFIG_DIR/controlplane.yaml" 2>&1; then
            echo "  ✓ Controlplane config applied successfully"
            APPLY_SUCCESS=true
            break
        else
            echo "  Attempt $attempt failed"
            if [[ $attempt -lt 3 ]]; then
                echo "  Waiting 10s before retry..."
                sleep 10
            fi
        fi
    done

    if [[ "$APPLY_SUCCESS" != "true" ]]; then
        echo "  ERROR: Failed to apply controlplane config"
        echo ""
        echo "  Possible causes:"
        echo "    1. Local registry not accessible (verify: ./scripts/verify-local-registry.sh)"
        echo "    2. Installer image not found in registry"
        echo "    3. Network issue between VM and host"
        echo ""
        echo "  Troubleshooting:"
        echo "    Check registry: curl -s http://${NETWORK_IP}:5000/v2/_catalog"
        echo "    Check VM console: virsh -c $LIBVIRT_URI console ${VM_PREFIX:-}${MASTER_NAME}"
        exit 1
    fi
else
    # ── Node is already configured — skipping apply-config ──
    echo "  Node $MASTER_NAME ($MASTER_IP) is already configured (not in maintenance mode)"
    echo "  Skipping config apply (config was already applied previously)"
    echo ""
    echo "  Verifying Talos API connectivity..."
    if talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep -q "Tag:"; then
        echo "  ✓ Talos API accessible with talosconfig"
    else
        echo "  WARNING: Could not verify Talos API — attempting apply-config anyway"
        # Last resort: try apply-config with talosconfig (works on some Talos versions)
        talosctl apply-config --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" --file "$CONFIG_DIR/controlplane.yaml" 2>&1 || true
    fi
fi

# ──────────────────────────────────────────────
# Phase 2: Wait for node to reboot (if config was applied)
# ──────────────────────────────────────────────
if [[ "$NODE_IN_MAINTENANCE" == "true" ]]; then
    echo ""
    echo "  ── Phase 2: Wait for node reboot ──"
    echo "  Node will reboot automatically after config is applied"
    echo "  Waiting for node to come back online..."

    REBOOT_WAIT=0
    REBOOT_TIMEOUT=180  # 3 minutes for reboot
    NODE_BACK=false

    while [[ $REBOOT_WAIT -lt $REBOOT_TIMEOUT ]]; do
        # After reboot, node will have certs from the applied config.
        # Use talosconfig (maintenance mode API is no longer available).
        version_output=$(talosctl version --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)

        if echo "$version_output" | grep -q "Tag:"; then
            echo "  ✓ Node is back online (${REBOOT_WAIT}s)"
            NODE_BACK=true
            break
        fi

        # Show progress periodically
        if [[ $((REBOOT_WAIT % 15)) -eq 0 ]]; then
            echo "    Waiting for node... (${REBOOT_WAIT}s)"
        fi

        sleep 5
        REBOOT_WAIT=$((REBOOT_WAIT + 5))
    done

    if [[ "$NODE_BACK" != "true" ]]; then
        echo "  ERROR: Node did not come back online after ${REBOOT_TIMEOUT}s"
        echo "  Check VM console for boot errors"
        exit 1
    fi

    # Additional stabilization time after reboot
    echo "  Allowing node to stabilize..."
    sleep 15
else
    echo ""
    echo "  ── Phase 2: Skip reboot wait ──"
    echo "  Node already running with config, no reboot needed"
fi

# ──────────────────────────────────────────────
# Phase 3: Bootstrap cluster (no --insecure)
# ──────────────────────────────────────────────
echo ""
echo "  ── Phase 3: Bootstrap cluster ──"
echo "  Node is configured and running. Bootstrapping etcd+K8s..."

BOOTSTRAP_SUCCESS=false
for attempt in 1 2 3 4 5; do
    echo "  Bootstrap attempt $attempt..."

    # In Talos v1.13, bootstrap uses talosconfig for auth (no --insecure flag)
    if talosctl bootstrap --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1; then
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
    echo ""
    exit 1
fi

echo ""
echo "  Waiting for cluster to initialize..."
sleep 10

# ──────────────────────────────────────────────
# Phase 4: Wait for cluster stability
# ──────────────────────────────────────────────
echo ""
echo "  ── Phase 4: Wait for cluster stability ──"

# Update talosconfig with correct endpoint
echo "  Updating talosconfig with endpoint..."
sed -i 's/endpoints: \[\]/endpoints: ["'"$MASTER_IP"'"]/g' "$CONFIG_DIR/talosconfig" 2>/dev/null || true
sed -i "s|endpoints: \[.*\]|endpoints: [\"$MASTER_IP\"]|g" "$CONFIG_DIR/talosconfig" 2>/dev/null || true

# Wait for cluster members to appear
STABILIZE_WAIT=0
STABILIZE_TIMEOUT=120
MEMBERS_FOUND=false

while [[ $STABILIZE_WAIT -lt $STABILIZE_TIMEOUT ]]; do
    members_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)

    if echo "$members_output" | grep -q "Member"; then
        echo "  ✓ Cluster is stable (${STABILIZE_WAIT}s)"
        echo ""
        echo "  Cluster members:"
        echo "$members_output" | grep "Member" | while IFS= read -r line; do
            echo "    $line"
        done
        MEMBERS_FOUND=true
        break
    fi

    if [[ $((STABILIZE_WAIT % 15)) -eq 0 ]]; then
        echo "    Waiting for cluster... (${STABILIZE_WAIT}s)"
    fi

    sleep 5
    STABILIZE_WAIT=$((STABILIZE_WAIT + 5))
done

if [[ "$MEMBERS_FOUND" != "true" ]]; then
    echo "  WARNING: Cluster may not be fully stable"
    if [[ -n "${members_output:-}" ]]; then
        echo "  Last output: $members_output"
    fi
fi

# Check etcd health
echo ""
echo "  Checking etcd health..."
ETCD_WAIT=0
ETCD_TIMEOUT=60
ETCD_OK=false

while [[ $ETCD_WAIT -lt $ETCD_TIMEOUT ]]; do
    etcd_output=$(talosctl get etcdmembers --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    etcd_count=$(echo "$etcd_output" | grep -c "EtcdMember" 2>/dev/null || echo "0")
    etcd_count=$(echo "$etcd_count" | tr -d '[:space:]')

    if [[ $etcd_count -ge 1 ]]; then
        echo "  ✓ etcd is healthy (${ETCD_WAIT}s)"
        ETCD_OK=true
        break
    fi

    if [[ $((ETCD_WAIT % 10)) -eq 0 ]]; then
        echo "    Waiting for etcd... (${ETCD_WAIT}s)"
    fi

    sleep 5
    ETCD_WAIT=$((ETCD_WAIT + 5))
done

if [[ "$ETCD_OK" != "true" ]]; then
    echo "  WARNING: etcd may not be fully healthy"
fi

# ──────────────────────────────────────────────
# Phase 5: Apply worker configs
# ──────────────────────────────────────────────
echo ""
echo "  ── Phase 5: Apply worker configs ──"
echo "  Workers: $WORKER_COUNT nodes ($WORKER_IP_BASE)"

if [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  WARNING: worker.yaml not found, skipping worker configuration"
else
    for i in $(seq 1 "$WORKER_COUNT"); do
        WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
        WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')

        echo ""
        echo "  Configuring $WORKER_NAME ($WORKER_IP)..."

        # Check if worker is in maintenance mode (should be for first-time setup)
        version_output=$(talosctl version --nodes "$WORKER_IP" --endpoints "$WORKER_IP" --insecure 2>&1 || true)

        if echo "$version_output" | grep -q "Tag:"; then
            echo "  ✓ Node is in maintenance mode"

            APPLY_OK=false
            for attempt in 1 2 3; do
                if talosctl apply-config --nodes "$WORKER_IP" --endpoints "$WORKER_IP" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1; then
                    echo "  ✓ Worker config applied (attempt $attempt)"
                    APPLY_OK=true
                    break
                else
                    echo "  Attempt $attempt failed"
                    [[ $attempt -lt 3 ]] && sleep 10
                fi
            done

            if [[ "$APPLY_OK" != "true" ]]; then
                echo "  ERROR: Failed to apply config to $WORKER_NAME"
                exit 1
            fi
        else
            echo "  WARNING: Unexpected state for $WORKER_NAME"
            echo "  Response: $(echo "$version_output" | head -3)"
            echo "  Attempting config apply anyway..."
            talosctl apply-config --nodes "$WORKER_IP" --endpoints "$WORKER_IP" --insecure --file "$CONFIG_DIR/worker.yaml" 2>&1 || true
        fi
    done
fi

# ──────────────────────────────────────────────
# Phase 6: Final verification
# ──────────────────────────────────────────────
echo ""
echo "  ── Phase 6: Verify all nodes ──"

EXPECTED_NODES=$((1 + WORKER_COUNT))
VERIFY_WAIT=0
VERIFY_TIMEOUT=120

while [[ $VERIFY_WAIT -lt $VERIFY_TIMEOUT ]]; do
    members_output=$(talosctl get members --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
    member_count=$(echo "$members_output" | grep -c "Member" 2>/dev/null || echo "0")
    member_count=$(echo "$member_count" | tr -d '[:space:]')

    if [[ $member_count -ge $EXPECTED_NODES ]]; then
        echo "  ✓ All $EXPECTED_NODES nodes present (${VERIFY_WAIT}s)"
        echo ""
        echo "  Cluster members:"
        echo "$members_output" | grep "Member" | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi

    if [[ $((VERIFY_WAIT % 15)) -eq 0 ]]; then
        echo "    Found $member_count/$EXPECTED_NODES nodes... (${VERIFY_WAIT}s)"
    fi

    sleep 5
    VERIFY_WAIT=$((VERIFY_WAIT + 5))
done

if [[ $VERIFY_WAIT -ge $VERIFY_TIMEOUT ]]; then
    echo "  WARNING: Only $member_count/$EXPECTED_NODES nodes found after ${VERIFY_TIMEOUT}s"
    echo "  Workers may still be joining the cluster"
fi

echo ""
echo "  ✓ Bootstrap phase complete"
echo ""
