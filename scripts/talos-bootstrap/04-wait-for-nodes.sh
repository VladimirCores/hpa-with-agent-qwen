#!/bin/bash
# =============================================================================
# Step 04: Wait for Nodes
# =============================================================================
# Waits for all Talos nodes to be accessible and responsive.
# Accepts both maintenance mode and cluster mode as "ready".
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/9] Waiting for nodes to be ready..."
echo "  Target nodes:"
echo "    - Master: $MASTER_NAME ($MASTER_IP)"
echo "    - Workers: $WORKER_COUNT nodes ($WORKER_IP_BASE)"
echo "  Timeout: 120s per node"
echo ""

# Function to check if node is responding
# Talos 1.13+ returns Server info even in maintenance mode via --insecure
# So we just check if the node is reachable (any version response)
check_node() {
    local ip="$1"
    local output
    output=$(talosctl version --nodes "$ip" --endpoints "$ip" --insecure 2>&1 || true)

    if echo "$output" | grep -q "Tag:"; then
        echo "ready"
    else
        echo "unreachable"
    fi
}

# Wait for master
echo "  Waiting for master ($MASTER_IP)..."
MASTER_WAIT=0
while [[ $MASTER_WAIT -lt 120 ]]; do
    status=$(check_node "$MASTER_IP")
    if [[ "$status" != "unreachable" ]]; then
        echo "  ✓ Master accessible (${status}, ${MASTER_WAIT}s)"
        break
    fi
    if [[ $((MASTER_WAIT % 10)) -eq 0 ]]; then
        echo "    ... waiting (${MASTER_WAIT}s)"
    fi
    sleep 2
    MASTER_WAIT=$((MASTER_WAIT + 2))
done

if [[ $MASTER_WAIT -ge 120 ]]; then
    echo "ERROR: Master not responding after 120s"
    echo "  Check VM status: virsh -c $LIBVIRT_URI list | grep talos"
    echo "  Check DHCP: virsh -c $LIBVIRT_URI net-dhcp-leases $NETWORK_NAME"
    echo "  Test manually: talosctl version --nodes $MASTER_IP --endpoints $MASTER_IP --insecure"
    exit 1
fi

# Wait for workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')

    echo "  Waiting for $WORKER_NAME ($WORKER_IP)..."
    WORKER_WAIT=0
    while [[ $WORKER_WAIT -lt 120 ]]; do
        status=$(check_node "$WORKER_IP")
        if [[ "$status" != "unreachable" ]]; then
            echo "  ✓ $WORKER_NAME accessible (${status}, ${WORKER_WAIT}s)"
            break
        fi
        if [[ $((WORKER_WAIT % 10)) -eq 0 ]]; then
            echo "    ... waiting (${WORKER_WAIT}s)"
        fi
        sleep 2
        WORKER_WAIT=$((WORKER_WAIT + 2))
    done

    if [[ $WORKER_WAIT -ge 120 ]]; then
        echo "ERROR: $WORKER_NAME not responding after 120s"
        echo "  Check VM: virsh -c $LIBVIRT_URI dominfo $WORKER_NAME"
        exit 1
    fi
done

echo ""
echo "  ✓ All nodes ready"
echo ""
