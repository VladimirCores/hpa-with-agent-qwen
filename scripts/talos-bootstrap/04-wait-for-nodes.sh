#!/bin/bash
# =============================================================================
# Step 04: Wait for Nodes to be Ready
# =============================================================================
# Waits for all Talos nodes to be accessible via the Talos API.
# Uses --insecure flag for pre-bootstrap connection.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/9] Waiting for nodes to be ready..."

MAX_WAIT=120

# Wait for master node
echo "  Waiting for master ($MASTER_IP)..."
WAITED=0
while ! talosctl get version --nodes "$MASTER_IP" --insecure &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "ERROR: Master not responding after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
done
echo "  ✓ Master ready (${WAITED}s)"

# Wait for worker nodes
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    
    echo "  Waiting for $WORKER_NAME ($WORKER_IP)..."
    WAITED=0
    while ! talosctl get version --nodes "$WORKER_IP" --insecure &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "ERROR: $WORKER_NAME not responding after ${MAX_WAIT}s"
            exit 1
        fi
        sleep 2
        WAITED=$((WAITED + 2))
        echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
    done
    echo "  ✓ $WORKER_NAME ready (${WAITED}s)"
done

echo ""
echo "  ✓ All nodes ready"
echo ""
