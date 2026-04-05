#!/bin/bash
# =============================================================================
# Step 08a: Change Boot Order to Disk After Talos Install
# =============================================================================
# After Talos installs from ISO to disk, we need to change boot order
# from CDROM-first to disk-first so VMs boot from the installed Talos.
# =============================================================================

set -euo pipefail

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_step() { echo -e "${YELLOW}▶ $1${NC}"; }

echo "[8a/12] Changing VM boot order to disk..."
echo ""

# Get VM names with prefix
VM_PREFIX="$(basename "$(dirname "$(dirname "$STEP_DIR")")")_"
VMS=("$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2")

for vm_name in "${VMS[@]}"; do
    actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${vm_name}" | awk '{print $2}' | head -1)
    
    if [[ -z "$actual_vm" ]]; then
        print_error "VM $vm_name not found"
        continue
    fi
    
    print_step "Changing boot order for $actual_vm..."
    
    # Export current XML
    xml=$(virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" 2>/dev/null) || continue
    
    # Remove cdrom boot entries
    xml=$(echo "$xml" | sed "/<boot dev='cdrom'>/d")
    
    # Ensure hd boot is first
    if echo "$xml" | grep -q "<boot dev='hd'/>"; then
        # Remove existing hd boot, then add it as first
        xml=$(echo "$xml" | sed "/<boot dev='hd'>/d")
        xml=$(echo "$xml" | sed "/<os>/a\    <boot dev='hd'/>")
    else
        xml=$(echo "$xml" | sed "/<os>/a\    <boot dev='hd'/>")
    fi
    
    # Apply new XML
    tmpfile=$(mktemp)
    echo "$xml" > "$tmpfile"
    
    if virsh -c "$LIBVIRT_URI" define "$tmpfile" >/dev/null 2>&1; then
        print_success "Boot order changed to disk for $actual_vm"
    else
        print_error "Failed to change boot order for $actual_vm"
    fi
    
    rm -f "$tmpfile"
done

echo ""
echo "✓ VMs configured to boot from disk on next reboot"
echo ""

exit 0
