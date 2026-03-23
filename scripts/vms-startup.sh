#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# All steps run synchronously, waiting for each to complete before continuing.
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
VERBOSE=false

while getopts "sfv" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        v) VERBOSE=true ;;
        *) echo "Usage: $0 [-s] [-f] [-v]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
           echo "  -v  Verbose output (detailed logging)"
           exit 1 ;;
    esac
done

echo "=== Talos Cluster VM Startup ==="
echo ""
echo "Configuration:"
echo "  NETWORK_NAME: $NETWORK_NAME"
echo "  MASTER_NAME: $MASTER_NAME ($MASTER_IP)"
echo "  WORKER_COUNT: $WORKER_COUNT"
echo "  SKIP_CLEANUP: $SKIP_CLEANUP"
echo "  FORCE_RESET: $FORCE_RESET"
echo "  VERBOSE: $VERBOSE"
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
    VERBOSE="$VERBOSE" \
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

# Execute steps asynchronously but wait for each to complete before continuing
echo "Executing steps..."
echo ""

# Execute a step asynchronously and wait for completion
run_step() {
    local step_name="$1"
    local step_func="$2"

    echo "Starting: $step_name"

    # Run step in background
    $step_func &
    local pid=$!

    # Wait for step to complete
    if wait $pid; then
        echo "  ✓ Completed (PID: $pid)"
    else
        echo "  ✗ Failed (PID: $pid)"
        exit 1
    fi
    echo ""
}

run_step "01: Authenticate sudo" "step_01_authenticate_sudo"
run_step "02: Check prerequisites" "step_02_check_prerequisites"
run_step "03: Prepare ISO" "step_03_prepare_iso"
run_step "04: Copy ISO to pool" "step_04_copy_iso_to_pool"
run_step "05: Setup network" "step_05_setup_network"
run_step "06: Cleanup VMs" "step_06_cleanup_vms"
run_step "07: Start VMs" "step_07_start_vms"
run_step "08: Wait for Talos boot" "step_08_wait_for_talos"
run_step "09: Eject ISO" "step_09_eject_iso"
run_step "10: Reboot and verify" "step_10_reboot_verify"
run_step "11: Summary" "step_11_summary"

echo "=== VM Startup Complete ==="
