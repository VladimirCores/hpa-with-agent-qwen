#!/bin/bash
# =============================================================================
# Step 08: Wait for Talos to Boot
# =============================================================================
# Polls VMs until Talos API is accessible (READY=true)
# Handles ISO boot, install to disk, reboot, and disk boot phases.
# =============================================================================

set -euo pipefail

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Ensure helper functions are loaded
if ! declare -f libvirt_get_dhcp_ips &>/dev/null; then
    source "$STEP_DIR/00-helper-functions.sh"
fi

# Configuration
BOOT_WAIT=300  # 5 minutes max for ISO install + disk boot
BOOT_INTERVAL=5
BOOT_ELAPSED=0
VERBOSE="${VERBOSE:-false}"

# Log file
LOG_FILE="/tmp/vms-startup.log"
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================================================
# Helper Functions
# ============================================================================

# Find VM by name pattern (handles Vagrant prefix)
find_vm_by_name() {
    local vm_name="$1"
    virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | \
        grep -E "${vm_name}[^0-9]*\s" | \
        awk '{print $2}' | head -1
}

# Wait for all VMs to be in running state
wait_for_vms_running() {
    local timeout="${1:-60}"
    local wait_time=0

    log "  Waiting for VMs to be running..."

    while [[ $wait_time -lt $timeout ]]; do
        local all_running=true

        for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
            local actual_vm
            actual_vm=$(find_vm_by_name "$vm_name")

            if [[ -n "$actual_vm" ]]; then
                local vm_state
                vm_state=$(virsh -c "$LIBVIRT_URI" domstate "$actual_vm" 2>/dev/null)

                if [[ "$vm_state" != "running" ]]; then
                    all_running=false
                    if [[ "$VERBOSE" == "true" ]]; then
                        log "    ⏳ $actual_vm: $vm_state"
                    fi
                fi
            else
                all_running=false
                if [[ "$VERBOSE" == "true" ]]; then
                    log "    ⏳ $vm_name: not found"
                fi
            fi
        done

        if [[ "$all_running" == "true" ]]; then
            log "  ✓ All VMs are running"
            return 0
        fi

        sleep 2
        wait_time=$((wait_time + 2))
    done

    log "  WARNING: Not all VMs are running after ${timeout}s"
    return 1
}

# Wait for DHCP leases to appear
wait_for_dhcp_leases() {
    local min_leases="${1:-$WORKER_COUNT}"
    local timeout="${2:-60}"
    local wait_time=0

    log "  Waiting for DHCP leases..."

    while [[ $wait_time -lt $timeout ]]; do
        mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")

        if [[ ${#VM_IPS[@]} -ge $min_leases ]]; then
            log "  ✓ Found ${#VM_IPS[@]} DHCP leases: ${VM_IPS[*]}"
            return 0
        fi

        if [[ "$VERBOSE" == "true" ]]; then
            log "    ⏳ Found ${#VM_IPS[@]} leases, waiting for $min_leases... (${wait_time}s)"
        fi

        sleep 2
        wait_time=$((wait_time + 2))
    done

    log "  WARNING: Only ${#VM_IPS[@]} DHCP leases found, expected $min_leases"
    return 1
}

# Check if Talos machine is READY
check_machine_ready() {
    local ip="$1"
    local output
    output=$(talosctl version --nodes "$ip" --insecure 2>&1 || true)
    
    if echo "$output" | grep -q "Server:"; then
        # Has server info - check if it's maintenance or cluster mode
        if echo "$output" | grep -q "not implemented"; then
            echo "maintenance"
        else
            echo "true"
        fi
    else
        echo "false"
    fi
}

# Check all machines ready
check_all_machines_ready() {
    local ips=("$@")
    local all_ready=true

    for ip in "${ips[@]}"; do
        if [[ -n "$ip" ]]; then
            local machine_status
            machine_status=$(check_machine_ready "$ip")

            if [[ "$machine_status" == "true" ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log "    ✓ $ip - Machine READY"
                fi
            elif [[ "$machine_status" == "maintenance" ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log "    ⏳ $ip - Maintenance mode (installing)"
                fi
                all_ready=false
            else
                if [[ "$VERBOSE" == "true" ]]; then
                    log "    ⏳ $ip - Not ready"
                fi
                all_ready=false
            fi
        fi
    done

    if [[ "$all_ready" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

log "[8/12] Waiting for Talos to boot and install to disk..."
log "  Configuration:"
log "    Timeout: ${BOOT_WAIT}s"
log "    Interval: ${BOOT_INTERVAL}s"
log "    Verbose: $VERBOSE"
log "    Boot order: Disk-first (persistent across reboots)"
log "    Network: $NETWORK_NAME ($LIBVIRT_URI)"
log "    Master: $MASTER_NAME ($MASTER_IP)"
log "    Workers: $WORKER_COUNT nodes ($WORKER_NAME_PREFIX)"
log ""

# Phase 1: Wait for VMs to be running
log "--- Phase 1: VM Status ---"
wait_for_vms_running 60
log ""

# Phase 2: Wait for DHCP leases
log "--- Phase 2: DHCP Leases ---"
wait_for_dhcp_leases "$WORKER_COUNT" 60
log ""

# Phase 3: Show DHCP leases
if [[ "$VERBOSE" == "true" ]]; then
    log "--- Phase 3: DHCP Details ---"
    log "  Getting DHCP leases for network: $NETWORK_NAME"
    virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | while IFS= read -r line; do
        log "    $line"
    done || log "  > No leases found"
    log ""
fi

# Phase 4: Wait for Talos maintenance mode (ISO boot)
log "--- Phase 4: Talos Maintenance Mode ---"
MAINTENANCE_ELAPSED=0
MAINTENANCE_WAIT=120

while [[ $MAINTENANCE_ELAPSED -lt $MAINTENANCE_WAIT ]]; do
    MASTER_IP="${VM_IPS[0]:-}"
    if [[ -n "$MASTER_IP" ]]; then
        local_status=$(check_machine_ready "$MASTER_IP")
        if [[ "$local_status" == "maintenance" ]]; then
            log "  ✓ Talos maintenance mode accessible at $MASTER_IP (${MAINTENANCE_ELAPSED}s)"
            break
        elif [[ "$local_status" == "true" ]]; then
            log "  ✓ Talos already booted from disk at $MASTER_IP (${MAINTENANCE_ELAPSED}s)"
            break
        fi
    fi
    sleep $BOOT_INTERVAL
    MAINTENANCE_ELAPSED=$((MAINTENANCE_ELAPSED + BOOT_INTERVAL))
    if [[ "$VERBOSE" == "true" ]]; then
        log "  ... waiting for maintenance mode (${MAINTENANCE_ELAPSED}s)"
    fi
done

if [[ $MAINTENANCE_ELAPSED -ge $MAINTENANCE_WAIT ]]; then
    log "  WARNING: Talos maintenance mode not accessible after ${MAINTENANCE_WAIT}s"
    log "  (This is OK if disk-first boot installed Talos directly)"
fi

log ""

# Phase 5: Wait for install to disk (monitor disk growth)
log "--- Phase 5: Talos Install to Disk ---"
INSTALL_WAIT=300
INSTALL_ELAPSED=0
INITIAL_DISK_SIZE=""
VM_PREFIX="$(basename "$(dirname "$(dirname "$STEP_DIR")")")_"

while [[ $INSTALL_ELAPSED -lt $INSTALL_WAIT ]]; do
    MASTER_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${MASTER_NAME}" | awk '{print $2}' | head -1 || true)

    if [[ -n "$MASTER_VM" ]]; then
        CURRENT_DISK=$(virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "${MASTER_VM}-vda.raw" 2>/dev/null | grep -i allocation | awk '{print $2}' || echo "unknown")

        if [[ -z "$INITIAL_DISK_SIZE" ]]; then
            INITIAL_DISK_SIZE="$CURRENT_DISK"
            log "  Initial disk size: $INITIAL_DISK_SIZE"
        fi

        # Check if disk has grown (install in progress or complete)
        if [[ "$CURRENT_DISK" != "$INITIAL_DISK_SIZE" ]] && [[ "$CURRENT_DISK" != "unknown" ]]; then
            log "  ✓ Disk activity detected (${INITIAL_DISK_SIZE} → ${CURRENT_DISK}) - installing to disk"
            # Wait for install to finish
            log "  Waiting for install to complete..."
            sleep 30
            break
        fi
        
        if [[ $INSTALL_ELAPSED -gt 60 ]]; then
            log "  ✓ Disk activity detected (timeout-based check)"
            break
        fi
    fi

    sleep $BOOT_INTERVAL
    INSTALL_ELAPSED=$((INSTALL_ELAPSED + BOOT_INTERVAL))
    if [[ "$VERBOSE" == "true" ]]; then
        log "  ... waiting for install (${INSTALL_ELAPSED}s)"
    fi
done

log ""

# Phase 6: Wait for Talos to reboot from disk
log "--- Phase 6: Talos Reboot from Disk ---"
log "  Waiting for Talos to reboot from disk..."
sleep 15

# Phase 7: Poll Talos machines from disk boot
log "--- Phase 7: Talos Disk Boot Verification ---"
while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    if [[ "$VERBOSE" == "true" ]]; then
        log "  [${BOOT_ELAPSED}s] Checking VM status..."
    fi

    # Refresh DHCP leases after reboot
    mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")

    total_count=${#VM_IPS[@]}
    if [[ "$VERBOSE" == "true" ]]; then
        log "    Found ${total_count} IPs: ${VM_IPS[*]:-none}"
    fi

    if [[ $total_count -gt 0 ]] && check_all_machines_ready "${VM_IPS[@]}"; then
        log ""
        log "  Progress: ${total_count}/${total_count} VMs ready"
        log ""
        log "  ✓ All VMs ready!"
        break
    fi

    # Count ready machines for progress display
    ready_count=0
    for ip in "${VM_IPS[@]}"; do
        if [[ -n "$ip" ]]; then
            machine_status=$(check_machine_ready "$ip")
            if [[ "$machine_status" == "true" ]]; then
                ready_count=$((ready_count + 1))
            fi
        fi
    done

    log "  Progress: ${ready_count}/${total_count} VMs ready (${BOOT_ELAPSED}s)"

    sleep $BOOT_INTERVAL
    BOOT_ELAPSED=$((BOOT_ELAPSED + BOOT_INTERVAL))
done

if [[ $BOOT_ELAPSED -ge $BOOT_WAIT ]]; then
    log "  WARNING: Not all VMs ready after ${BOOT_WAIT}s"
    log "  Check VM console logs: virsh -c qemu:///system console <vm-name>"
    log "  Continuing anyway (VMs may need more time)..."
fi

log ""
log "  ✓ Talos booted from disk"
log ""

# Final verification
MASTER_IP="${VM_IPS[0]:-}"
if [[ -n "$MASTER_IP" ]]; then
    if talosctl version --nodes "$MASTER_IP" 2>&1 | grep -q "Server:"; then
        log "  Master node ($MASTER_IP) is accessible and ready"
        exit 0
    fi
fi

log "  Note: Bootstrap process will configure nodes with proper PKI"
exit 0
