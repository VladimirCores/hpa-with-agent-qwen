#!/bin/bash
# Step 08: Wait for Talos to boot from ISO
# Polls VMs until Talos API is accessible (READY=true)

echo "[8/11] Waiting for Talos to boot from ISO..."

# Wait for each VM to be accessible via Talos API
BOOT_WAIT=300  # 5 minutes max
BOOT_INTERVAL=5
BOOT_ELAPSED=0

echo "  Waiting for Talos API to be accessible..."
echo "  (Polling every ${BOOT_INTERVAL}s, timeout ${BOOT_WAIT}s)"
echo ""

while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    echo "  [${BOOT_ELAPSED}s] Checking VM status..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    # Get all IPs from libvirt network
    mapfile -t VM_IPS < <(get_libvirt_ips "$NETWORK_NAME" "ipv4")

    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))

        # Find VM with matching suffix
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)

        if [[ -n "$ACTUAL_VM" ]]; then
            # Get VM state
            VM_STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep "State:" | awk '{print $2}')

            # Get IP for this VM from the list
            VM_IP=""
            for ip in "${VM_IPS[@]}"; do
                # Check if this IP belongs to this VM by checking MAC address
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
                # Check machine READY status
                MACHINE_READY=$(check_machine_ready "$VM_IP")
                if [[ "$MACHINE_READY" == "true" ]]; then
                    echo "    ✓ $ACTUAL_VM ($VM_IP) - Machine READY"
                    READY_COUNT=$((READY_COUNT + 1))
                    continue
                else
                    # Get current machine status for more info
                    if [[ -n "$MACHINE_READY" ]]; then
                        echo "    ⏳ $ACTUAL_VM ($VM_IP) - Machine status: $MACHINE_READY (state: $VM_STATE)"
                    else
                        echo "    ⏳ $ACTUAL_VM ($VM_IP) - Waiting for machine status (state: $VM_STATE)"
                    fi
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
        echo "  All VMs ready!"
        break
    fi

    sleep $BOOT_INTERVAL
    BOOT_ELAPSED=$((BOOT_ELAPSED + BOOT_INTERVAL))
done

if [[ "$ALL_READY" != "true" ]]; then
    echo "  WARNING: Not all VMs ready after ${BOOT_WAIT}s"
    echo "  Check VM console logs: virsh -c qemu:///system console <vm-name>"
    echo ""
    echo "  Continuing anyway (VMs may need more time)..."
fi

echo ""
echo "  ✓ Talos booted from ISO"
echo ""
