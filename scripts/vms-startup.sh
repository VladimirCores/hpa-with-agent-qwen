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

while getopts "sf" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        *) echo "Usage: $0 [-s] [-f]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
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

# Execute steps synchronously (one by one, waiting for each to complete)
echo "Executing steps..."
echo ""

echo "Step 1/11: Authenticate sudo"
step_01_authenticate_sudo
echo ""

echo "Step 2/11: Check prerequisites"
step_02_check_prerequisites
echo ""

echo "Step 3/11: Prepare ISO"
step_03_prepare_iso
echo ""

echo "Step 4/11: Copy ISO to pool"
step_04_copy_iso_to_pool
echo ""

echo "Step 5/11: Setup network"
step_05_setup_network
echo ""

echo "Step 6/11: Cleanup VMs"
step_06_cleanup_vms
echo ""

echo "Step 7/11: Start VMs"
step_07_start_vms
echo ""

echo "Step 8/11: Wait for Talos boot"
step_08_wait_for_talos
echo ""

echo "Step 9/11: Eject ISO"
step_09_eject_iso
echo ""

echo "Step 10/11: Reboot and verify"
step_10_reboot_verify
echo ""

echo "Step 11/11: Summary"
step_11_summary
echo ""

echo "=== VM Startup Complete ==="
