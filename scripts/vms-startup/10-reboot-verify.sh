#!/bin/bash
# Step 09: Reboot VMs and verify disk boot
# Reboots all VMs and verifies they boot from disk

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Ensure helper functions are loaded
if ! declare -f libvirt_get_dhcp_ips &>/dev/null; then
    source "$STEP_DIR/00-helper-functions.sh"
fi

if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    echo "[9/10] Rebooting VMs to verify disk boot..."
    echo "  (Raw image mode - VMs boot from pre-installed disk)"
else
    echo "[9/10] Rebooting VMs to verify disk boot..."
    echo "  (ISO mode - VMs reboot after installation)"
fi

REBOOT_WAIT=300  # 5 minutes max
REBOOT_INTERVAL=5
REBOOT_ELAPSED=0

# Reboot all VMs
echo "  Sending reboot command to all VMs..."
mapfile -t ALL_VMS < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "with-agent-qwen" | awk '{print $2}')
for actual_vm in "${ALL_VMS[@]}"; do
    if [[ -n "$actual_vm" ]]; then
        echo "  Rebooting $actual_vm..."
        virsh -c "$LIBVIRT_URI" reboot "$actual_vm" 2>/dev/null || true
    fi
done

echo ""
echo "  Waiting for VMs to reboot from disk..."
echo "  (Polling every ${REBOOT_INTERVAL}s, timeout ${REBOOT_WAIT}s)"
echo ""

while [[ $REBOOT_ELAPSED -lt $REBOOT_WAIT ]]; do
    echo "  [${REBOOT_ELAPSED}s] Checking VM status after reboot..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    # Get all IPs from libvirt network
    mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")
    TOTAL_COUNT=${#VM_IPS[@]}

    # Check each IP directly
    for vm_ip in "${VM_IPS[@]}"; do
        if [[ -n "$vm_ip" ]]; then
            if talosctl get version --nodes "$vm_ip" --insecure &>/dev/null; then
                echo "    ✓ $vm_ip - Booted from disk ✓"
                READY_COUNT=$((READY_COUNT + 1))
            else
                echo "    ⏳ $vm_ip - Waiting for Talos API"
                ALL_READY=false
            fi
        fi
    done

    echo ""
    echo "  Progress: ${READY_COUNT}/${TOTAL_COUNT} VMs ready"
    echo ""

    if [[ "$ALL_READY" == "true" ]]; then
        echo "  All VMs booted from disk successfully!"
        break
    fi

    sleep $REBOOT_INTERVAL
    REBOOT_ELAPSED=$((REBOOT_ELAPSED + REBOOT_INTERVAL))
done

if [[ "$ALL_READY" != "true" ]]; then
    echo "  WARNING: Not all VMs ready after reboot"
    echo "  Check VM console logs: virsh -c qemu:///system console <vm-name>"
else
    echo "  ✓ All VMs booted from disk successfully"
fi
echo ""
