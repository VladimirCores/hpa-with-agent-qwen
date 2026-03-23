#!/bin/bash
# Step 08: Wait for Talos to boot from ISO
# Polls VMs until Talos API is accessible (READY=true)
#
# Usage:
#   Sync:  bash 08-wait-for-talos.sh
#   Async: bash 08-wait-for-talos.sh &  # Runs in background

# Ensure helper functions are loaded
if ! declare -f libvirt_get_dhcp_ips &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/00-helper-functions.sh"
fi

# Configuration
BOOT_WAIT=300  # 5 minutes max
BOOT_INTERVAL=5
BOOT_ELAPSED=0

echo "[8/12] Waiting for Talos to boot from ISO..."

# Wait for each VM to be accessible via Talos API
echo "  Waiting for Talos API to be accessible..."
echo "  (Polling every ${BOOT_INTERVAL}s, timeout ${BOOT_WAIT}s)"
echo ""

while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    echo "  [${BOOT_ELAPSED}s] Checking VM status..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    # Get all IPs from libvirt network
    mapfile -t VM_IPS < <(libvirt_get_dhcp_ips -n "$NETWORK_NAME" -p ipv4 -r)
    TOTAL_COUNT=${#VM_IPS[@]}

    # Check each IP directly
    for vm_ip in "${VM_IPS[@]}"; do
        if [[ -n "$vm_ip" ]]; then
            # Check machine READY status
            MACHINE_READY=$(check_machine_ready "$vm_ip")
            if [[ "$MACHINE_READY" == "true" ]]; then
                echo "    ✓ $vm_ip - Machine READY"
                READY_COUNT=$((READY_COUNT + 1))
            else
                if [[ -n "$MACHINE_READY" ]]; then
                    echo "    ⏳ $vm_ip - Machine status: $MACHINE_READY"
                else
                    echo "    ⏳ $vm_ip - Waiting for machine status"
                fi
                ALL_READY=false
            fi
        fi
    done

    if [[ "$ALL_READY" == "true" ]]; then
        echo ""
        echo "  Progress: ${READY_COUNT}/${TOTAL_COUNT} VMs ready"
        echo ""
        echo "  All VMs ready!"
        break
    else
        echo ""
        echo "  Progress: ${READY_COUNT}/${TOTAL_COUNT} VMs ready"
        echo ""
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
