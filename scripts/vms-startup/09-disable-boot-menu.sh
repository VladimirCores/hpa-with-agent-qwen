#!/bin/bash
# =============================================================================
# Step 09: Disable Boot Menu for Talos VMs
# =============================================================================
# Disables the boot menu for all VMs to enable faster boot without menu delay.
# This must run after VMs are created but before they are used.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[9/12] Disabling boot menu for faster startup..."

# Function to disable boot menu for a VM
disable_boot_menu() {
    local vm_name="$1"
    
    # Find the actual VM name (Vagrant may add prefixes)
    local actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}" | awk '{print $2}' | head -1)
    
    if [[ -z "$actual_vm" ]]; then
        echo "  VM not found: $vm_name"
        return 1
    fi
    
    # Check current bootmenu status
    local current=$(virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" 2>/dev/null | grep "bootmenu" | head -1)
    
    if echo "$current" | grep -q "enable='yes'"; then
        # Stop the VM
        virsh -c "$LIBVIRT_URI" destroy "$actual_vm" 2>/dev/null || true
        sleep 2
        
        # Dump XML, modify, and redefine
        local tmpfile=$(mktemp)
        virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" > "$tmpfile" 2>/dev/null
        sed -i "s/bootmenu enable='yes'/bootmenu enable='no'/g" "$tmpfile"
        
        # Redefine and start
        virsh -c "$LIBVIRT_URI" define "$tmpfile" >/dev/null 2>&1
        virsh -c "$LIBVIRT_URI" start "$actual_vm" 2>/dev/null
        
        rm -f "$tmpfile"
        echo "  ✓ Boot menu disabled: $actual_vm"
    elif echo "$current" | grep -q "enable='no'"; then
        echo "  ✓ Boot menu already disabled: $actual_vm"
    else
        echo "  ✓ Boot menu default (disabled): $actual_vm"
    fi
}

# Disable boot menu for all VMs
disable_boot_menu "$MASTER_NAME"
for i in $(seq 1 $WORKER_COUNT); do
    disable_boot_menu "${WORKER_NAME_PREFIX}${i}"
done

echo ""
