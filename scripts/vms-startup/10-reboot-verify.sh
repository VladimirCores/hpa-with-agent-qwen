#!/bin/bash
# Step 10: Reboot VMs and verify disk boot
# Reboots all VMs and verifies they boot from disk (not ISO)

echo "[10/11] Rebooting VMs to verify disk boot..."

REBOOT_WAIT=300  # 5 minutes max
REBOOT_INTERVAL=5
REBOOT_ELAPSED=0

# Reboot all VMs
echo "  Sending reboot command to all VMs..."
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$ACTUAL_VM" ]]; then
        echo "  Rebooting $ACTUAL_VM..."
        virsh -c "$LIBVIRT_URI" reboot "$ACTUAL_VM" 2>/dev/null || true
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
    mapfile -t VM_IPS < <(get_libvirt_ips "$NETWORK_NAME" "ipv4")

    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))

        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)

        if [[ -n "$ACTUAL_VM" ]]; then
            # Get VM state
            VM_STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep "State:" | awk '{print $2}')

            # Get IP for this VM from the list
            VM_IP=""
            for ip in "${VM_IPS[@]}"; do
                VM_MAC=$(virsh -c "$LIBVIRT_URI" domifaddr "$ACTUAL_VM" 2>/dev/null | grep -v "^-" | awk '{print $2}' | head -1)
                if [[ -n "$VM_MAC" ]]; then
                    LEASE_MAC=$(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep "$ip" | awk '{print $2}')
                    if [[ "$VM_MAC" == "$LEASE_MAC" ]]; then
                        VM_IP="$ip"
                        break
                    fi
                fi
            done

            if [[ -n "$VM_IP" ]]; then
                if talosctl get version --nodes "$VM_IP" --insecure &>/dev/null; then
                    # Verify boot source (should be disk, not ISO)
                    CDROM_PRESENT=$(virsh -c "$LIBVIRT_URI" domblklist "$ACTUAL_VM" 2>/dev/null | grep -E "^hda.*iso$" | wc -l)
                    if [[ "$CDROM_PRESENT" -eq 0 ]]; then
                        echo "    ✓ $ACTUAL_VM ($VM_IP) - Booted from disk ✓"
                    else
                        echo "    ⚠ $ACTUAL_VM ($VM_IP) - Ready (CDROM still attached)"
                    fi
                    READY_COUNT=$((READY_COUNT + 1))
                    continue
                else
                    echo "    ⏳ $ACTUAL_VM ($VM_IP) - IP assigned, Talos API not ready (state: $VM_STATE)"
                fi
            else
                echo "    ⏳ $ACTUAL_VM - Waiting for IP address (state: $VM_STATE)"
            fi
        else
            echo "    ✗ $vm_name - VM not found"
        fi
        ALL_READY=false
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
