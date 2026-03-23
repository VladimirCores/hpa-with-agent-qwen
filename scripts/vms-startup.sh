#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# Each step is called as a function with explicit parameters from .env.
# Steps can run synchronously or asynchronously based on --async flag.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/vms-startup"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "ERROR: .env file not found in $PROJECT_ROOT" >&2
    exit 1
fi

# Parse arguments
SKIP_CLEANUP=false
FORCE_RESET=false
EXECUTE=false
ASYNC=false

while getopts "sefa" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        e) EXECUTE=true ;;
        a) ASYNC=true ;;
        *) echo "Usage: $0 [-s] [-f] [-e] [-a]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
           echo "  -e  Execute steps (default: false - show plan only)"
           echo "  -a  Run steps asynchronously (default: false - synchronous)"
           exit 1 ;;
    esac
done

# Set defaults
EXECUTE="${EXECUTE:-false}"
ASYNC="${ASYNC:-false}"

echo "=== Talos Cluster VM Startup ==="
echo ""
echo "Configuration:"
echo "  NETWORK_NAME: $NETWORK_NAME"
echo "  MASTER_NAME: $MASTER_NAME ($MASTER_IP)"
echo "  WORKER_COUNT: $WORKER_COUNT"
echo "  SKIP_CLEANUP: $SKIP_CLEANUP"
echo "  FORCE_RESET: $FORCE_RESET"
echo "  EXECUTE: $EXECUTE"
echo "  ASYNC: $ASYNC"
echo ""

# Source helper functions
source "$STEPS_DIR/00-helper-functions.sh"

# Define step functions
step_01_authenticate_sudo() {
    bash "$STEPS_DIR/01-authenticate-sudo.sh"
}

step_02_check_prerequisites() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/02-check-prerequisites.sh"
}

step_03_prepare_iso() {
    TALOS_IMAGE_URL="$TALOS_IMAGE_URL" \
    TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH" \
    bash "$STEPS_DIR/03-prepare-iso.sh"
}

step_04_copy_iso_to_pool() {
    STORAGE_POOL="$STORAGE_POOL" \
    TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/04-copy-iso-to-pool.sh"
}

step_05_setup_network() {
    NETWORK_NAME="$NETWORK_NAME" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    bash "$STEPS_DIR/05-setup-network.sh"
}

step_06_cleanup_vms() {
    SKIP_CLEANUP="$SKIP_CLEANUP" \
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/06-cleanup-vms.sh"
}

step_07_start_vms() {
    SKIP_CLEANUP="$SKIP_CLEANUP" \
    FORCE_RESET="$FORCE_RESET" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STEPS_DIR/07-start-vms.sh"
}

step_08_wait_for_talos() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/08-wait-for-talos.sh"
}

step_09_eject_iso() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/09-eject-iso.sh"
}

step_10_reboot_verify() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/10-reboot-verify.sh"
}

step_11_summary() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    CLUSTER_NAME="${CLUSTER_NAME:-talos-cluster}" \
    bash "$STEPS_DIR/11-summary.sh"
}

# Execute steps
if [[ "$EXECUTE" == "false" ]]; then
    echo "Dry run mode. Use -e to execute steps."
    echo ""
    echo "Steps to execute:"
    echo "  1. step_01_authenticate_sudo"
    echo "  2. step_02_check_prerequisites"
    echo "  3. step_03_prepare_iso"
    echo "  4. step_04_copy_iso_to_pool"
    echo "  5. step_05_setup_network"
    echo "  6. step_06_cleanup_vms"
    echo "  7. step_07_start_vms"
    echo "  8. step_08_wait_for_talos (async with -a flag)"
    echo "  9. step_09_eject_iso"
    echo " 10. step_10_reboot_verify"
    echo " 11. step_11_summary"
    echo ""
    exit 0
fi

echo "Executing steps..."
echo ""

# Execute a step (sync or async)
execute_step() {
    local step_name="$1"
    local step_func="$2"
    local run_async="${3:-false}"

    echo "Starting: $step_name"

    if [[ "$run_async" == "true" ]]; then
        $step_func &
        local pid=$!
        echo "  → Running async (PID: $pid)"
        wait $pid
        if [[ $? -ne 0 ]]; then
            echo "  ✗ Failed"
            return 1
        fi
        echo "  ✓ Completed"
    else
        if $step_func; then
            echo "  ✓ Completed"
        else
            echo "  ✗ Failed"
            return 1
        fi
    fi
    echo ""
}

# Steps 01-07: Run synchronously
execute_step "01: Authenticate sudo" "step_01_authenticate_sudo" "false"
execute_step "02: Check prerequisites" "step_02_check_prerequisites" "false"
execute_step "03: Prepare ISO" "step_03_prepare_iso" "false"
execute_step "04: Copy ISO to pool" "step_04_copy_iso_to_pool" "false"
execute_step "05: Setup network" "step_05_setup_network" "false"
execute_step "06: Cleanup VMs" "step_06_cleanup_vms" "false"
execute_step "07: Start VMs" "step_07_start_vms" "false"

# Step 08: Run asynchronously but WAIT for completion before continuing
echo "Starting: 08: Wait for Talos boot"
if [[ "$ASYNC" == "true" ]]; then
    echo "  → Running async, will wait for completion..."
    step_08_wait_for_talos &
    STEP08_PID=$!
    echo "  → PID: $STEP08_PID"
    echo ""
    echo "Waiting for step 08 to complete..."
    if ! wait $STEP08_PID; then
        echo "✗ Step 08 failed (PID: $STEP08_PID)"
        exit 1
    fi
    echo "✓ Step 08 completed (PID: $STEP08_PID)"
else
    echo "  → Running sync..."
    echo ""
    if ! step_08_wait_for_talos; then
        echo "✗ Step 08 failed"
        exit 1
    fi
    echo "✓ Step 08 completed"
fi
echo ""

# Steps 09-11: Run synchronously (only after step 08 completes)
execute_step "09: Eject ISO" "step_09_eject_iso" "false"
execute_step "10: Reboot and verify" "step_10_reboot_verify" "false"
execute_step "11: Summary" "step_11_summary" "false"

echo "=== VM Startup Complete ==="
