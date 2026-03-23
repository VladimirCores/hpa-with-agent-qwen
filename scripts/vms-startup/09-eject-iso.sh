#!/bin/bash
# Step 09: Eject ISO and set disk boot
# Ejects ISO from all VMs and updates boot order to disk-only

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[9/11] Ejecting ISO and setting disk boot..."

# Get all VMs
mapfile -t ALL_VMS < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "with-agent-qwen" | awk '{print $2}')

for actual_vm in "${ALL_VMS[@]}"; do
    if [[ -n "$actual_vm" ]]; then
        # Eject ISO from CDROM
        virsh -c "$LIBVIRT_URI" change-media-device "$actual_vm" --path hda --eject 2>/dev/null || true

        # Update boot order: disk first, cdrom removed
        xml=$(virsh -c "$LIBVIRT_URI" dumpxml "$actual_vm" 2>/dev/null)
        if echo "$xml" | grep -q "<boot dev='cdrom'/>"; then
            # Remove cdrom boot entry, keep only hd
            echo "$xml" | sed "/<boot dev='cdrom'\/>/d" | virsh -c "$LIBVIRT_URI" define /dev/stdin 2>/dev/null || true
        fi

        echo "    ✓ ISO ejected from $actual_vm"
    fi
done

echo "  ✓ ISO ejected, boot order set to disk-only"
echo ""
