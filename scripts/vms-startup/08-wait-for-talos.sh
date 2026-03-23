#!/bin/bash
# Step 08: Wait for Talos to boot from ISO
# Polls VMs until Talos API is accessible (READY=true)
#
# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Usage:
#   Sync:  bash 08-wait-for-talos.sh
#   Async: bash 08-wait-for-talos.sh &  # Runs in background
#   Verbose: VERBOSE=true bash 08-wait-for-talos.sh

# Ensure helper functions are loaded
if ! declare -f libvirt_get_dhcp_ips &>/dev/null; then
    source "$STEP_DIR/00-helper-functions.sh"
fi

# Configuration
BOOT_WAIT=300  # 5 minutes max
BOOT_INTERVAL=5
BOOT_ELAPSED=0
VERBOSE="${VERBOSE:-true}"

echo "[8/12] Waiting for Talos to boot from ISO..."
echo "  Configuration:"
echo "    Timeout: ${BOOT_WAIT}s"
echo "    Interval: ${BOOT_INTERVAL}s"
echo "    Verbose: $VERBOSE"
echo ""

# Wait for each VM to be accessible via Talos API
echo "  Waiting for Talos API to be accessible..."
echo "  (Polling every ${BOOT_INTERVAL}s, timeout ${BOOT_WAIT}s)"
echo ""

# Initial network check
if [[ "$VERBOSE" == "true" ]]; then
    echo "  > Getting DHCP leases for network: $NETWORK_NAME"
    virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "  > No leases found"
    echo ""
fi

while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    echo "  [${BOOT_ELAPSED}s] Checking VM status..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    # Get all IPs from libvirt network
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  > Querying DHCP leases..."
    fi
    mapfile -t VM_IPS < <(libvirt_get_dhcp_ips -n "$NETWORK_NAME" -p ipv4 -r)
    TOTAL_COUNT=${#VM_IPS[@]}

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  > Found ${TOTAL_COUNT} IPs: ${VM_IPS[*]}"
    fi

    # Check each IP directly
    for vm_ip in "${VM_IPS[@]}"; do
        if [[ -n "$vm_ip" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "  > Checking machine status for IP: $vm_ip"
            fi

            # Check machine READY status
            MACHINE_READY=$(check_machine_ready "$vm_ip")

            if [[ "$VERBOSE" == "true" ]]; then
                echo "  > Machine READY status for $vm_ip: $MACHINE_READY"
            fi

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
        else
            if [[ "$VERBOSE" == "true" ]]; then
                echo "  > Skipping empty IP"
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
