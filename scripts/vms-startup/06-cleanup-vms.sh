#!/bin/bash
# =============================================================================
# Step 06: Clean up existing VMs and disks
# =============================================================================
# Removes old VM disks to ensure fresh Talos installation.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

if [[ "$SKIP_CLEANUP" == "false" ]]; then
    echo "[6/10] Cleaning up existing VMs and disks..."
    echo "  Storage pool: $STORAGE_POOL"
    echo "  Libvirt URI: $LIBVIRT_URI"
    echo "  Raw image mode: ${USE_RAW_IMAGE:-false}"
    echo ""

    # Clean up raw image overlays from storage pool
    if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
        echo "  Cleaning raw image overlays from storage pool..."
        OVERLAY_COUNT=0
        for vol in $(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | awk '{print $1}' | grep -v "talos-base-image"); do
            echo "    Removing: $vol"
            if virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null; then
                OVERLAY_COUNT=$((OVERLAY_COUNT + 1))
            fi
        done
        echo "  ✓ Removed $OVERLAY_COUNT overlay volumes"

        # Also clean local overlay directory if exists
        OVERLAY_DIR="$PROJECT_ROOT/.vagrant/raw-disks"
        if [[ -d "$OVERLAY_DIR" ]]; then
            LOCAL_OVERLAYS=$(find "$OVERLAY_DIR" -name "*.qcow2" 2>/dev/null | wc -l)
            if [[ $LOCAL_OVERLAYS -gt 0 ]]; then
                echo "  Cleaning $LOCAL_OVERLAYS local overlay files..."
                rm -f "$OVERLAY_DIR"/*.qcow2 2>/dev/null || true
            fi
        fi
    fi

    # Remove other disk volumes from storage pool
    echo "  Removing remaining storage pool volumes..."
    VOLUME_COUNT=0
    for vol in $(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | awk '{print $1}' | grep -v "\.iso$" | grep -v "talos-base-image"); do
        echo "    Removing: $vol"
        if virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null; then
            VOLUME_COUNT=$((VOLUME_COUNT + 1))
        fi
    done
    echo "  ✓ Removed $VOLUME_COUNT volumes"

    # Destroy and undefine existing VMs
    echo "  Destroying and undefining existing VMs..."
    VM_COUNT=0
    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        # Find VM with matching suffix (handles Vagrant prefix)
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
        if [[ -n "$ACTUAL_VM" ]]; then
            echo "    VM: $ACTUAL_VM"
            echo "      Destroying..."
            virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true

            # Wait for VM to stop
            WAIT=0
            while virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep -q "State:.*running"; do
                sleep 0.5
                WAIT=$((WAIT + 1))
                if [[ $WAIT -gt 20 ]]; then
                    echo "      WARNING: VM not stopped after 10s, forcing..."
                    virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true
                    break
                fi
            done

            echo "      Undefining..."
            virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" --remove-all-storage 2>/dev/null || \
                virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" 2>/dev/null || true
            VM_COUNT=$((VM_COUNT + 1))
        fi
    done
    echo "  ✓ Cleaned up $VM_COUNT VMs"

    if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
        echo "  ✓ Cleanup complete (overlays wiped for fresh Talos boot)"
    else
        echo "  ✓ Cleanup complete (disks wiped for fresh Talos install)"
    fi
else
    echo "[6/10] Skipping cleanup (using -s flag)"
fi
echo ""
