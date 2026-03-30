#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# All steps run synchronously, waiting for each to complete before continuing.
# Supports both ISO-based installation and raw disk image provisioning.
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

# Export all variables for subprocesses
export NETWORK_NAME MASTER_NAME MASTER_IP WORKER_COUNT
export WORKER_NAME_PREFIX WORKER_IP_BASE STORAGE_POOL LIBVIRT_URI
export SKIP_CLEANUP FORCE_RESET VERBOSE CLUSTER_NAME TALOS_IMAGE_URL TALOS_IMAGE_PATH
export USE_RAW_IMAGE TALOS_RAW_IMAGE_PATH TALOS_RAW_IMAGE_COMPRESSED
export SUDO_USER
export MASTER_DISK WORKER_DISK

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
echo "  USE_RAW_IMAGE: ${USE_RAW_IMAGE:-false}"
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

step_03_prepare_image() {
    if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
        TALOS_RAW_IMAGE_URL="$TALOS_RAW_IMAGE_URL" \
        TALOS_RAW_IMAGE_PATH="$TALOS_RAW_IMAGE_PATH" \
        TALOS_RAW_IMAGE_COMPRESSED="$TALOS_RAW_IMAGE_COMPRESSED" \
        bash "$STEPS_DIR/03-prepare-raw-image.sh"
    else
        TALOS_IMAGE_URL="$TALOS_IMAGE_URL" \
        TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH" \
        bash "$STEPS_DIR/03-prepare-iso.sh"
    fi
}

step_04_prepare_storage() {
    if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
        FORCE_RESET="$FORCE_RESET" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        bash "$STEPS_DIR/04-create-vm-disks.sh"
    else
        STORAGE_POOL="$STORAGE_POOL" \
        TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH" \
        LIBVIRT_URI="$LIBVIRT_URI" \
        bash "$STEPS_DIR/04-copy-iso-to-pool.sh"
    fi
}

step_04_create_storage_pool() {
    STORAGE_POOL="$STORAGE_POOL" \
    POOL_PATH="$POOL_PATH" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/04-create-storage-pool.sh"
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
    USE_RAW_IMAGE="${USE_RAW_IMAGE:-false}" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STEPS_DIR/06-cleanup-vms.sh"
}

step_07_start_vms() {
    SKIP_CLEANUP="$SKIP_CLEANUP" \
    FORCE_RESET="$FORCE_RESET" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STEPS_DIR/07-start-vms.sh"
}

step_08_wait_for_talos() {
    # Source the step script directly to preserve environment
    source "$STEPS_DIR/08-wait-for-talos.sh"
}

step_08b_apply_cilium_configs() {
    # Apply Cilium-ready configs immediately after Talos boots
    # This MUST run before Talos installs to disk
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STEPS_DIR/08b-apply-cilium-configs.sh"
}

step_09_disable_boot_menu() {
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    bash "$STEPS_DIR/09-disable-boot-menu.sh"
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
    USE_RAW_IMAGE="${USE_RAW_IMAGE:-false}" \
    bash "$STEPS_DIR/11-summary.sh"
}

# Execute steps
echo "Executing steps..."
echo ""

# Execute a step synchronously
run_step_sync() {
    local step_name="$1"
    local step_func="$2"

    echo "Starting: $step_name"

    if $step_func; then
        echo "  ✓ Completed"
    else
        echo "  ✗ Failed"
        exit 1
    fi
    echo ""
}

# Steps 01-09: Run synchronously
run_step_sync "01: Authenticate sudo" "step_01_authenticate_sudo"
run_step_sync "02: Check prerequisites" "step_02_check_prerequisites"
run_step_sync "03: Prepare disk image" "step_03_prepare_image"
run_step_sync "04: Create storage pool" "step_04_create_storage_pool"
run_step_sync "05: Setup network" "step_05_setup_network"
run_step_sync "06: Cleanup VMs" "step_06_cleanup_vms"
run_step_sync "07: Start VMs" "step_07_start_vms"
run_step_sync "08: Create CoW overlays" "step_04_prepare_storage"
run_step_sync "09: Disable boot menu" "step_09_disable_boot_menu"

# Step 08: Wait for Talos (source directly to preserve sudo context)
echo "Starting: 08: Wait for Talos boot"
step_08_wait_for_talos
echo "  ✓ Completed"
echo ""

# Step 08b: Apply Cilium configs (CRITICAL - must run before Talos installs)
echo "Starting: 08b: Apply Cilium-Ready Configs"
step_08b_apply_cilium_configs
echo "  ✓ Completed"
echo ""

# Steps 09-11: Run synchronously
run_step_sync "09: Disable boot menu" "step_09_disable_boot_menu"
run_step_sync "10: Reboot and verify" "step_10_reboot_verify"
run_step_sync "11: Summary" "step_11_summary"

echo "=== VM Startup Complete ==="
