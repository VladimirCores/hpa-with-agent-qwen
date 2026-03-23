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

# Wait for VMs to be running and have DHCP leases
echo "  > Waiting for VMs to be running..."
VM_WAIT=0
while [[ $VM_WAIT -lt 60 ]]; do
    ALL_RUNNING=true
    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        # Find VM with matching suffix (handles Vagrant prefix)
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1)
        if [[ -n "$ACTUAL_VM" ]]; then
            VM_STATE=$(virsh -c "$LIBVIRT_URI" domstate "$ACTUAL_VM" 2>/dev/null)
            if [[ "$VM_STATE" != "running" ]]; then
                ALL_RUNNING=false
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "    ⏳ $ACTUAL_VM: $VM_STATE"
                fi
            fi
        else
            ALL_RUNNING=false
            if [[ "$VERBOSE" == "true" ]]; then
                echo "    ⏳ $vm_name: not found"
            fi
        fi
    done

    if [[ "$ALL_RUNNING" == "true" ]]; then
        echo "  ✓ All VMs are running"
        break
    fi

    sleep 2
    VM_WAIT=$((VM_WAIT + 2))
done

if [[ "$ALL_RUNNING" != "true" ]]; then
    echo "  WARNING: Not all VMs are running after 60s"
fi

# Wait for DHCP leases
echo ""
echo "  > Waiting for DHCP leases..."
LEASE_WAIT=0
while [[ $LEASE_WAIT -lt 60 ]]; do
    mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")
    if [[ ${#VM_IPS[@]} -ge $WORKER_COUNT ]]; then
        echo "  ✓ Found ${#VM_IPS[@]} DHCP leases: ${VM_IPS[*]}"
        break
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo "    ⏳ Found ${#VM_IPS[@]} leases, waiting for $WORKER_COUNT..."
    fi

    sleep 2
    LEASE_WAIT=$((LEASE_WAIT + 2))
done

if [[ ${#VM_IPS[@]} -lt $WORKER_COUNT ]]; then
    echo "  WARNING: Only ${#VM_IPS[@]} DHCP leases found, expected $WORKER_COUNT"
fi

echo ""

# Initial network check
if [[ "$VERBOSE" == "true" ]]; then
    echo "  > Getting DHCP leases for network: $NETWORK_NAME in $LIBVIRT_URI"
    virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "  > No leases found"
    echo ""
fi

while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    echo "  [${BOOT_ELAPSED}s] Checking VM status..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=${#VM_IPS[@]}

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  > Checking ${TOTAL_COUNT} IPs..."
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
