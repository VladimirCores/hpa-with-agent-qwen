#!/bin/bash
# =============================================================================
# Disable Boot Menu for Talos VMs
# =============================================================================
# This script disables the boot menu for all Talos VMs after they are created.
# Run this after 'vagrant up' to prevent boot menu from appearing on startup.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

echo "=== Disabling Boot Menu for Talos VMs ==="
echo ""

# Function to disable boot menu for a VM
disable_boot_menu() {
    local vm_name="$1"
    
    # Find the actual VM name (Vagrant may add prefixes)
    local actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}" | awk '{print $2}' | head -1)
    
    if [[ -z "$actual_vm" ]]; then
        echo "  VM not found: $vm_name"
        return 1
    fi
    
    echo "  Processing: $actual_vm"
    
    # Check current bootmenu status
    local current=$(virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" 2>/dev/null | grep "bootmenu" | head -1)
    
    if echo "$current" | grep -q "enable='yes'"; then
        echo "    Boot menu is enabled, disabling..."
        
        # Stop the VM
        echo "    Stopping VM..."
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
        
        # Verify
        sleep 5
        local new_current=$(virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" 2>/dev/null | grep "bootmenu" | head -1)
        if echo "$new_current" | grep -q "enable='no'"; then
            echo "    ✓ Boot menu disabled"
        else
            echo "    ✗ Failed to disable boot menu"
            return 1
        fi
    elif echo "$current" | grep -q "enable='no'"; then
        echo "    ✓ Boot menu already disabled"
    else
        echo "    ✓ No bootmenu element found (disabled by default)"
    fi
}

# Disable boot menu for all VMs
disable_boot_menu "$MASTER_NAME"
for i in $(seq 1 $WORKER_COUNT); do
    disable_boot_menu "${WORKER_NAME_PREFIX}${i}"
done

echo ""
echo "=== Boot Menu Disabled ==="
echo ""
echo "All VMs now have boot menu disabled permanently."
