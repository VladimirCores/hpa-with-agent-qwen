#!/bin/bash
# =============================================================================
# Talos Cluster Cleanup Script
# =============================================================================
# Stops and cleans up Talos cluster VMs and resources
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMS_STARTUP_DIR="$SCRIPT_DIR/scripts/vms-startup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
export NETWORK_NAME MASTER_NAME WORKER_COUNT WORKER_NAME_PREFIX
export STORAGE_POOL LIBVIRT_URI USE_RAW_IMAGE PROJECT_ROOT

# Parse arguments
DESTROY_NETWORK=false
FULL_CLEANUP=false

while getopts "nf" opt; do
    case $opt in
        n) DESTROY_NETWORK=true ;;
        f) FULL_CLEANUP=true ;;
        *) echo "Usage: $0 [-n] [-f]"
           echo "  -n  Destroy network (preserve by default)"
           echo "  -f  Full cleanup (destroy network and storage)"
           exit 1 ;;
    esac
done

# If full cleanup, enable network destruction
if [[ "$FULL_CLEANUP" == "true" ]]; then
    DESTROY_NETWORK=true
fi

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
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# =============================================================================
# Main Script
# =============================================================================

print_header "Talos Cluster Cleanup"

echo "Configuration:"
echo "  LIBVIRT_URI:   $LIBVIRT_URI"
echo "  NETWORK_NAME:  $NETWORK_NAME"
echo "  STORAGE_POOL:  $STORAGE_POOL"
echo ""
echo "Options:"
echo "  DESTROY_NETWORK: $DESTROY_NETWORK"
echo "  FULL_CLEANUP:    $FULL_CLEANUP"
echo ""

# Confirm full cleanup
if [[ "$FULL_CLEANUP" == "true" ]]; then
    echo -e "${YELLOW}⚠ FULL CLEANUP: This will destroy VMs, network, and storage!${NC}"
    read -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Step 1: Stop VMs
# =============================================================================
print_header "Step 1/4: Stop VMs"

print_step "Stopping VMs via Vagrant..."
cd "$SCRIPT_DIR"

if vagrant halt 2>/dev/null; then
    print_success "VMs stopped via Vagrant"
else
    echo "  Vagrant halt failed, trying direct virsh..."
fi

# Force stop any remaining VMs
echo ""
print_step "Force stopping remaining VMs..."
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "with-agent-qwen_${vm}" | awk '{print $2}' || true)
    if [[ -n "$actual_vm" ]]; then
        echo "  Stopping: $actual_vm"
        virsh -c "$LIBVIRT_URI" destroy "$actual_vm" 2>/dev/null || true
        print_success "Stopped $actual_vm"
    fi
done

# =============================================================================
# Step 2: Cleanup Vagrant State
# =============================================================================
print_header "Step 2/4: Cleanup Vagrant State"

print_step "Destroying Vagrant VMs..."
if vagrant destroy -f 2>/dev/null; then
    print_success "Vagrant VMs destroyed"
else
    echo "  Vagrant destroy failed, continuing..."
fi

# =============================================================================
# Step 3: Cleanup Storage
# =============================================================================
print_header "Step 3/4: Cleanup Storage"

print_step "Removing storage volumes..."

# Remove volumes from pool
if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
    virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | while read -r vol rest; do
        [[ -z "$vol" ]] && continue
        echo "  Removing: $vol"
        virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null && \
            echo "    ✓ Removed" || echo "    ✗ Failed"
    done
    print_success "Storage volumes cleaned"
else
    echo "  Storage pool not found, skipping"
fi

# Remove project-local storage directory
if [[ -d "$SCRIPT_DIR/.vagrant/storage-pool" ]]; then
    print_step "Removing project-local storage..."
    rm -rf "$SCRIPT_DIR/.vagrant/storage-pool"
    print_success "Project storage removed"
fi

# Destroy storage pool if full cleanup
if [[ "$FULL_CLEANUP" == "true" ]]; then
    print_step "Destroying storage pool..."
    if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
        virsh -c "$LIBVIRT_URI" pool-destroy "$STORAGE_POOL" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" pool-undefine "$STORAGE_POOL" 2>/dev/null || true
        print_success "Storage pool destroyed"
    fi
fi

# =============================================================================
# Step 4: Cleanup Network
# =============================================================================
if [[ "$DESTROY_NETWORK" == "true" ]]; then
    print_header "Step 4/4: Destroy Network"
    
    print_step "Destroying network..."
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
        virsh -c "$LIBVIRT_URI" net-destroy "$NETWORK_NAME" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" net-undefine "$NETWORK_NAME" 2>/dev/null || true
        print_success "Network destroyed"
    else
        echo "  Network not found, skipping"
    fi
else
    print_header "Step 4/4: Preserve Network"
    print_success "Network preserved"
fi

# =============================================================================
# Summary
# =============================================================================
print_header "Cleanup Complete"

echo -e "${GREEN}Cluster cleanup completed!${NC}"
echo ""
echo "To start the cluster again:"
echo "  ./startup.sh"
echo ""
echo "For full cleanup (including network):"
echo "  ./cleanup.sh -f"
echo ""

exit 0
