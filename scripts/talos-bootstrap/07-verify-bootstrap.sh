#!/bin/bash
# =============================================================================
# Step 07: Verify Bootstrap and Wait for Reboot
# =============================================================================
# Waits for nodes to reboot after applying configuration and verifies bootstrap.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[7/9] Waiting for nodes to reboot..."

MAX_WAIT=180

# Wait for master to reboot
echo "  Waiting for master ($MASTER_IP)..."
WAITED=0
while ! talosctl get version --nodes "$MASTER_IP" --insecure &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "ERROR: Master not ready after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
done
echo "  ✓ Master rebooted (${WAITED}s)"

# Wait for workers to reboot
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    
    echo "  Waiting for $WORKER_NAME ($WORKER_IP)..."
    WAITED=0
    while ! talosctl get version --nodes "$WORKER_IP" --insecure &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "ERROR: $WORKER_NAME not ready after ${MAX_WAIT}s"
            exit 1
        fi
        sleep 2
        WAITED=$((WAITED + 2))
        echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
    done
    echo "  ✓ $WORKER_NAME rebooted (${WAITED}s)"
done

# Verify bootstrap worked
echo ""
echo "  Verifying bootstrap..."
sleep 5

if talosctl get members --nodes "$MASTER_IP" --insecure &>/dev/null; then
    echo "  ✓ Bootstrap verified"
    echo ""
    echo "  Cluster members:"
    talosctl get members --nodes "$MASTER_IP" --insecure 2>/dev/null | head -10
else
    echo "  WARNING: Unable to verify bootstrap"
fi

# Change boot order to disk (optional helper)
echo ""
echo "  Setting VM boot order to disk..."
if [[ -x "$STEP_DIR/../set-boot-order.sh" ]]; then
    "$STEP_DIR/../set-boot-order.sh" 2>/dev/null || echo "    WARNING: Could not change boot order"
else
    echo "    Note: set-boot-order.sh not found, skipping"
fi

echo ""
echo "  ✓ Bootstrap verification complete"
echo ""
