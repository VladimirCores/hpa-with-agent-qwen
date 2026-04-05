#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs - Structured Step-by-Step Execution
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# Each step executes sequentially and must complete successfully before continuing.
# Supports both ISO-based installation and raw disk image provisioning.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/vms-startup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo -e "${RED}ERROR: .env file not found in $PROJECT_ROOT${NC}" >&2
    exit 1
fi

# Export all variables for subprocesses
export NETWORK_NAME MASTER_NAME MASTER_IP WORKER_COUNT
export WORKER_NAME_PREFIX WORKER_IP_BASE STORAGE_POOL LIBVIRT_URI
export SKIP_CLEANUP FORCE_RESET VERBOSE CLUSTER_NAME TALOS_IMAGE_URL TALOS_IMAGE_PATH
export USE_RAW_IMAGE TALOS_RAW_IMAGE_PATH TALOS_RAW_IMAGE_COMPRESSED
export SUDO_USER MASTER_DISK WORKER_DISK FORWARD_MODE

# Set POOL_PATH if not defined in .env
POOL_PATH="${POOL_PATH:-$PROJECT_ROOT/.vagrant/storage-pool}"
export POOL_PATH

# Parse arguments
SKIP_CLEANUP=false
FORCE_RESET=false
VERBOSE=false

# VM name prefix (derived from project directory name, used by vagrant-libvirt)
VM_PREFIX="$(basename "$PROJECT_ROOT")_"

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

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}▶ Step $1: $2${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_script="$3"
    shift 3
    
    print_step "$step_num" "$step_name"
    
    if bash "$step_script" "$@"; then
        print_success "$step_name completed"
        return 0
    else
        print_error "$step_name failed"
        echo ""
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  Startup failed at step $step_num: $step_name${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check the error message above"
        echo "  2. Review logs in /tmp/vms-startup.log"
        echo "  3. Run with -v for verbose output"
        echo "  4. Fix the issue and re-run: $0"
        echo ""
        exit 1
    fi
}

verify_step() {
    local step_name="$1"
    local verify_cmd="$2"
    
    echo "  Verifying: $step_name..."
    
    if eval "$verify_cmd" > /dev/null 2>&1; then
        print_success "Verification passed: $step_name"
        return 0
    else
        print_error "Verification failed: $step_name"
        return 1
    fi
}

# =============================================================================
# Main Script
# =============================================================================

print_header "Talos Cluster VM Startup"

echo "Configuration:"
echo "  LIBVIRT_URI:    $LIBVIRT_URI"
echo "  NETWORK_NAME:   $NETWORK_NAME"
echo "  FORWARD_MODE:   ${FORWARD_MODE:-nat}"
echo "  MASTER_NAME:    $MASTER_NAME ($MASTER_IP)"
echo "  WORKER_COUNT:   $WORKER_COUNT"
echo "  USE_RAW_IMAGE:  ${USE_RAW_IMAGE:-false}"
echo "  STORAGE_POOL:   $STORAGE_POOL"
echo "  POOL_PATH:      ${POOL_PATH:-auto}"
echo ""
echo "Options:"
echo "  SKIP_CLEANUP:   $SKIP_CLEANUP"
echo "  FORCE_RESET:    $FORCE_RESET"
echo "  VERBOSE:        $VERBOSE"
echo ""

# Read confirmation for force reset
if [[ "$FORCE_RESET" == "true" ]]; then
    echo -e "${YELLOW}⚠ FORCE RESET MODE: This will destroy all VMs and disks!${NC}"
    read -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
print_header "Step 1/8: Check Prerequisites"

run_step "1" "Checking prerequisites" "$STEPS_DIR/02-check-prerequisites.sh" \
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI"

# =============================================================================
# Step 2: Prepare Talos Image
# =============================================================================
print_header "Step 2/8: Prepare Talos Image"

if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    run_step "2" "Preparing raw disk image" "$STEPS_DIR/03-prepare-raw-image.sh" \
        TALOS_RAW_IMAGE_URL="$TALOS_RAW_IMAGE_URL" \
        TALOS_RAW_IMAGE_PATH="$TALOS_RAW_IMAGE_PATH" \
        TALOS_RAW_IMAGE_COMPRESSED="$TALOS_RAW_IMAGE_COMPRESSED"
else
    run_step "2" "Preparing ISO image" "$STEPS_DIR/03-prepare-iso.sh" \
        TALOS_IMAGE_URL="$TALOS_IMAGE_URL" \
        TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH"
fi

# =============================================================================
# Step 3: Create Storage Pool
# =============================================================================
print_header "Step 3/8: Create Storage Pool"

run_step "3" "Creating storage pool" "$STEPS_DIR/04-create-storage-pool.sh" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI"

# Storage pool verification done in step script
print_success "Storage pool verification passed (from step script)"

# =============================================================================
# Step 4: Setup Network
# =============================================================================
print_header "Step 4/8: Setup Network"

run_step "4" "Setting up network" "$STEPS_DIR/05-setup-network.sh" \
    NETWORK_NAME="$NETWORK_NAME" \
    SCRIPT_DIR="$SCRIPT_DIR"

# Network verification done in step script, skip duplicate check
print_success "Network verification passed (from step script)"

# =============================================================================
# Step 5: Cleanup Existing VMs (if not skipped)
# =============================================================================
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    print_header "Step 5/8: Cleanup Existing VMs"
    
    run_step "5" "Cleaning up existing VMs" "$STEPS_DIR/06-cleanup-vms.sh" \
        SKIP_CLEANUP="$SKIP_CLEANUP" \
        NETWORK_NAME="$NETWORK_NAME" \
        MASTER_NAME="$MASTER_NAME" \
        WORKER_COUNT="$WORKER_COUNT" \
        WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
        STORAGE_POOL="$STORAGE_POOL" \
        LIBVIRT_URI="$LIBVIRT_URI" \
        USE_RAW_IMAGE="${USE_RAW_IMAGE:-false}" \
        PROJECT_ROOT="$PROJECT_ROOT"
else
    print_header "Step 5/8: Skip Cleanup (requested)"
    print_success "Skipping VM cleanup"
fi

# =============================================================================
# Step 6: Start VMs with Vagrant
# =============================================================================
print_header "Step 6/8: Start VMs"

cd "$PROJECT_ROOT"

# Check VM state: compare Vagrant status with libvirt
need_cleanup=false
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    # Check libvirt
    actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${vm}" | awk '{print $2}' | head -1)
    
    # Check vagrant status
    vm_status=$(vagrant status "$vm" 2>/dev/null | grep -E "not created|running|saved|poweroff" | awk '{print $2}' | head -1)
    
    if [[ -n "$actual_vm" ]] && [[ "$vm_status" != "running" ]]; then
        # VM exists in libvirt but Vagrant doesn't see it as running
        # This happens when VMs were created outside Vagrant or state is out of sync
        need_cleanup=true
        echo "  Orphaned VM found: $actual_vm (Vagrant status: $vm_status)"
    fi
done

if [[ "$need_cleanup" == "true" ]]; then
    echo ""
    echo "  Cleaning up orphaned VMs from libvirt..."
    for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
        actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${vm}" | awk '{print $2}' | head -1)
        if [[ -n "$actual_vm" ]]; then
            echo "    Destroying: $actual_vm"
            run_sudo virsh -c "$LIBVIRT_URI" destroy "$actual_vm" 2>/dev/null || true
            run_sudo virsh -c "$LIBVIRT_URI" undefine "$actual_vm" 2>/dev/null || true
            # Also remove disk if exists
            disk_name="${actual_vm}-vda.raw"
            run_sudo virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$disk_name" 2>/dev/null || true
        fi
    done
    echo "  ✓ Orphaned VMs cleaned up"
    echo ""
fi

echo "Starting VMs with Vagrant..."
if vagrant up --provider=libvirt 2>&1 | tee /tmp/vagrant-up.log; then
    # Check the actual exit status of vagrant up
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        # Check if error is about existing domains
        if grep -q "already taken" /tmp/vagrant-up.log 2>/dev/null; then
            print_error "VM domains already exist in libvirt"
            echo ""
            echo "Existing VMs found but not managed by Vagrant. Options:"
            echo "  1. Run with -f flag to force cleanup and recreate"
            echo "  2. Manually destroy: virsh -c $LIBVIRT_URI undefine --remove-all-storage <vm-name>"
            exit 1
        fi
        print_error "Vagrant failed to start VMs"
        echo ""
        echo "Check /tmp/vagrant-up.log for details"
        exit 1
    fi
    print_success "VMs started successfully"
else
    print_error "Vagrant failed to start VMs"
    echo ""
    echo "Check /tmp/vagrant-up.log for details"
    exit 1
fi

# Verify VMs are running
echo ""
echo "Verifying VMs..."
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    if virsh -c "$LIBVIRT_URI" domstate "${VM_PREFIX}$vm" 2>/dev/null | grep -q "running"; then
        print_success "VM $vm is running"
    else
        print_error "VM $vm is not running"
        exit 1
    fi
done

# =============================================================================
# Step 7: Configure UEFI (if needed)
# =============================================================================
print_header "Step 7/8: Configure UEFI"

run_step "7" "Configuring UEFI" "$STEPS_DIR/08b-configure-uefi.sh" \
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_MEMORY="$MASTER_MEMORY" \
    MASTER_CPUS="$MASTER_CPUS" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    WORKER_MEMORY="$WORKER_MEMORY" \
    WORKER_CPUS="$WORKER_CPUS" \
    POOL_PATH="$POOL_PATH" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH"

# =============================================================================
# Step 8: Wait for Talos to Boot
# =============================================================================
print_header "Step 8/8: Wait for Talos Boot"

run_step "8" "Waiting for Talos boot" "$STEPS_DIR/08-wait-for-talos.sh" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    LIBVIRT_URI="$LIBVIRT_URI"

# =============================================================================
# Summary
# =============================================================================
print_header "Startup Complete"

echo -e "${GREEN}All VMs started successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Bootstrap Talos cluster:"
echo "     ./scripts/talos-bootstrap.sh"
echo ""
echo "  2. Monitor VM status:"
echo "     virsh -c $LIBVIRT_URI list"
echo ""
echo "  3. Access VM console (if needed):"
echo "     virsh -c $LIBVIRT_URI console ${VM_PREFIX}$MASTER_NAME"
echo ""

exit 0
