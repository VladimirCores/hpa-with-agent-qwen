#!/bin/bash
# =============================================================================
# Talos Cluster Startup Script
# =============================================================================
# Starts the Talos Kubernetes cluster VMs step-by-step
# Each step must complete successfully before continuing
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMS_STARTUP_DIR="$SCRIPT_DIR/scripts/vms-startup"
PREPARE_NETWORK="$SCRIPT_DIR/scripts/prepare-network.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source .env file
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo -e "${RED}ERROR: .env file not found${NC}"
    exit 1
fi

# Export variables
export NETWORK_NAME MASTER_NAME MASTER_IP WORKER_COUNT
export WORKER_NAME_PREFIX WORKER_IP_BASE STORAGE_POOL LIBVIRT_URI
export USE_RAW_IMAGE TALOS_RAW_IMAGE_PATH TALOS_RAW_IMAGE_COMPRESSED
export TALOS_IMAGE_URL TALOS_IMAGE_PATH POOL_PATH FORWARD_MODE

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
           echo "  -s  Skip cleanup"
           echo "  -f  Force reset (destroy VMs and disks)"
           echo "  -v  Verbose output"
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

print_header "Talos Cluster Startup"

echo "Configuration:"
echo "  LIBVIRT_URI:    $LIBVIRT_URI"
echo "  NETWORK_NAME:   $NETWORK_NAME"
echo "  FORWARD_MODE:   ${FORWARD_MODE:-nat}"
echo "  MASTER_NAME:    $MASTER_NAME ($MASTER_IP)"
echo "  WORKER_COUNT:   $WORKER_COUNT"
echo "  USE_RAW_IMAGE:  ${USE_RAW_IMAGE:-false}"
echo "  STORAGE_POOL:   $STORAGE_POOL"
echo ""
echo "Options:"
echo "  SKIP_CLEANUP:   $SKIP_CLEANUP"
echo "  FORCE_RESET:    $FORCE_RESET"
echo ""

# Confirm force reset
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

run_step "1" "Checking prerequisites" "$VMS_STARTUP_DIR/02-check-prerequisites.sh"

# =============================================================================
# Step 2: Prepare Talos Image
# =============================================================================
print_header "Step 2/8: Prepare Talos Image"

if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    run_step "2" "Preparing raw disk image" "$VMS_STARTUP_DIR/03-prepare-raw-image.sh"
else
    run_step "2" "Preparing ISO image" "$VMS_STARTUP_DIR/03-prepare-iso.sh"
fi

# =============================================================================
# Step 3: Create Storage Pool
# =============================================================================
print_header "Step 3/8: Create Storage Pool"

run_step "3" "Creating storage pool" "$VMS_STARTUP_DIR/04-create-storage-pool.sh"

verify_step "Storage pool exists" \
    "virsh -c '$LIBVIRT_URI' pool-info '$STORAGE_POOL'"

# =============================================================================
# Step 4: Setup Network
# =============================================================================
print_header "Step 4/8: Setup Network"

run_step "4" "Setting up network" "$VMS_STARTUP_DIR/05-setup-network.sh"

sleep 2
verify_step "Network is active" \
    "virsh -c '$LIBVIRT_URI' net-info '$NETWORK_NAME' 2>/dev/null | grep -q 'Active.*yes'"

# =============================================================================
# Step 5: Cleanup Existing VMs
# =============================================================================
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    print_header "Step 5/8: Cleanup Existing VMs"
    
    run_step "5" "Cleaning up existing VMs" "$VMS_STARTUP_DIR/06-cleanup-vms.sh" \
        SKIP_CLEANUP="$SKIP_CLEANUP" \
        NETWORK_NAME="$NETWORK_NAME" \
        MASTER_NAME="$MASTER_NAME" \
        WORKER_COUNT="$WORKER_COUNT" \
        WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
        STORAGE_POOL="$STORAGE_POOL" \
        LIBVIRT_URI="$LIBVIRT_URI" \
        USE_RAW_IMAGE="${USE_RAW_IMAGE:-false}" \
        PROJECT_ROOT="$SCRIPT_DIR"
else
    print_header "Step 5/8: Skip Cleanup"
    print_success "Skipping VM cleanup"
fi

# =============================================================================
# Step 6: Start VMs
# =============================================================================
print_header "Step 6/8: Start VMs"

cd "$SCRIPT_DIR"

echo "Starting VMs with Vagrant..."
if vagrant up --provider=libvirt 2>&1 | tee /tmp/vagrant-up.log; then
    print_success "VMs started successfully"
else
    print_error "Vagrant failed to start VMs"
    echo "Check /tmp/vagrant-up.log for details"
    exit 1
fi

# Verify VMs
echo ""
echo "Verifying VMs..."
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    if virsh -c "$LIBVIRT_URI" domstate "with-agent-qwen_$vm" 2>/dev/null | grep -q "running"; then
        print_success "VM $vm is running"
    else
        print_error "VM $vm is not running"
        exit 1
    fi
done

# =============================================================================
# Step 7: Configure UEFI
# =============================================================================
print_header "Step 7/8: Configure UEFI"

run_step "7" "Configuring UEFI" "$VMS_STARTUP_DIR/08b-configure-uefi.sh" \
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
# Step 8: Wait for Talos Boot
# =============================================================================
print_header "Step 8/8: Wait for Talos Boot"

run_step "8" "Waiting for Talos boot" "$VMS_STARTUP_DIR/08-wait-for-talos.sh"

# =============================================================================
# Summary
# =============================================================================
print_header "Startup Complete"

echo -e "${GREEN}All VMs started successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Bootstrap Talos cluster:"
echo "     ./bootstrap.sh"
echo ""
echo "  2. Monitor VM status:"
echo "     virsh -c $LIBVIRT_URI list"
echo ""

exit 0
