#!/bin/bash
# =============================================================================
# Step 04: Wait for Nodes
# =============================================================================
# Waits for all Talos nodes to be accessible and responsive.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/9] Waiting for nodes to be ready..."
echo "  Target nodes:"
echo "    - Master: $MASTER_NAME ($MASTER_IP)"
echo "    - Workers: $WORKER_COUNT nodes ($WORKER_IP_BASE)"
echo "  Timeout: 120s"
echo ""

# Wait for master
echo "  Waiting for master ($MASTER_IP)..."
MASTER_WAIT=0
while [[ $MASTER_WAIT -lt 120 ]]; do
    if talosctl version --nodes "$MASTER_IP" --insecure 2>&1 | grep -q "v1\."; then
        echo "  ✓ Master ready (${MASTER_WAIT}s)"
        break
    fi
    echo "    ... waiting (${MASTER_WAIT}s)"
    sleep 2
    MASTER_WAIT=$((MASTER_WAIT + 2))
done

if [[ $MASTER_WAIT -ge 120 ]]; then
    echo "ERROR: Master not responding after 120s"
    echo "  Check VM status: virsh -c $LIBVIRT_URI list | grep talos"
    echo "  Check DHCP: virsh -c $LIBVIRT_URI net-dhcp-leases $NETWORK_NAME"
    exit 1
fi

# Wait for workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    
    echo "  Waiting for $WORKER_NAME ($WORKER_IP)..."
    WORKER_WAIT=0
    while [[ $WORKER_WAIT -lt 120 ]]; do
        if talosctl version --nodes "$WORKER_IP" --insecure 2>&1 | grep -q "v1\."; then
            echo "  ✓ $WORKER_NAME ready (${WORKER_WAIT}s)"
            break
        fi
        echo "    ... waiting (${WORKER_WAIT}s)"
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
