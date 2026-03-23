#!/bin/bash
# Step 06: Clean up existing VMs and disks
# Removes old VM disks to ensure fresh Talos installation

if [[ "$SKIP_CLEANUP" == "false" ]]; then
    echo "[6/11] Cleaning up existing VMs and disks..."

    # Remove disk volumes first (ensures fresh install)
    echo "  Removing disk volumes..."
    for vol in $(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | awk '{print $1}' | grep -v "\.iso$"); do
        echo "    Removing: $vol"
        virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null || true
    done

    # Destroy and undefine existing VMs
    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        # Find VM with matching suffix (handles Vagrant prefix)
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
        if [[ -n "$ACTUAL_VM" ]]; then
            echo "  Destroying VM: $ACTUAL_VM"
            virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true

            # Wait for VM to stop
            while virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep -q "State:.*running"; do
                sleep 0.5
            done

            echo "  Undefining VM: $ACTUAL_VM"
            virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" --remove-all-storage 2>/dev/null || \
            virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" 2>/dev/null || true
        fi
    done

    echo "  ✓ Cleanup complete (disks wiped for fresh Talos install)"
else
    echo "[6/11] Skipping cleanup (using -s flag)"
fi
echo ""
