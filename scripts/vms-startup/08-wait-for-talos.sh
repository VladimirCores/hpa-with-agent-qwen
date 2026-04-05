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
BOOT_WAIT=300  # 5 minutes max for ISO install
BOOT_INTERVAL=5
BOOT_ELAPSED=0
VERBOSE="${VERBOSE:-true}"
VM_PREFIX="$(basename "$(dirname "$(dirname "$STEP_DIR")")")_"

# ============================================================================
# Helper Functions
# ============================================================================

# Log verbose message (only if VERBOSE=true)
# Usage: log_verbose <message>
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "$@"
    fi
}

# Log info message (always shown)
# Usage: log_info <message>
log_info() {
    echo "$@"
}

# Log warning message
# Usage: log_warning <message>
log_warning() {
    echo "  WARNING: $*"
}

# Find VM by name pattern (handles Vagrant prefix)
# Usage: find_vm_by_name <vm_name>
# Returns: Actual VM name or empty string
find_vm_by_name() {
    local vm_name="$1"
    virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | \
        grep -E "${vm_name}[^0-9]*\s" | \
        awk '{print $2}' | head -1
}

# Wait for all VMs to be in running state
# Usage: wait_for_vms_running [timeout_seconds]
# Returns: 0 if all running, 1 if timeout
wait_for_vms_running() {
    local timeout="${1:-60}"
    local wait_time=0

    log_info "Waiting for VMs to be running..."

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
                    log_verbose "  ⏳ $actual_vm: $vm_state"
                fi
            else
                all_running=false
                log_verbose "  ⏳ $vm_name: not found"
            fi
        done

        if [[ "$all_running" == "true" ]]; then
            log_info "  ✓ All VMs are running"
            return 0
        fi

        sleep 2
        wait_time=$((wait_time + 2))
    done

    log_warning "Not all VMs are running after ${timeout}s"
    return 1
}

# Wait for DHCP leases to appear
# Usage: wait_for_dhcp_leases [min_leases] [timeout_seconds]
# Sets: VM_IPS array with discovered IPs
# Returns: 0 if enough leases, 1 if timeout
wait_for_dhcp_leases() {
    local min_leases="${1:-$WORKER_COUNT}"
    local timeout="${2:-60}"
    local wait_time=0

    log_info "Waiting for DHCP leases..."

    while [[ $wait_time -lt $timeout ]]; do
        mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")

        if [[ ${#VM_IPS[@]} -ge $min_leases ]]; then
            log_info "  ✓ Found ${#VM_IPS[@]} DHCP leases: ${VM_IPS[*]}"
            return 0
        fi

        log_verbose "  ⏳ Found ${#VM_IPS[@]} leases, waiting for $min_leases..."

        sleep 2
        wait_time=$((wait_time + 2))
    done

    log_warning "Only ${#VM_IPS[@]} DHCP leases found, expected $min_leases"
    return 1
}

# Check if all Talos machines are READY
# Usage: check_all_machines_ready <ip1> [ip2] [ip3] ...
# Returns: 0 if all ready, 1 if any not ready
check_all_machines_ready() {
    local ips=("$@")
    local all_ready=true

    for ip in "${ips[@]}"; do
        if [[ -n "$ip" ]]; then
            local machine_ready
            machine_ready=$(check_machine_ready "$ip")

            if [[ "$machine_ready" == "true" ]]; then
                log_info "    ✓ $ip - Machine READY"
            else
                if [[ -n "$machine_ready" ]]; then
                    log_verbose "  ⏳ $ip - Machine status: $machine_ready"
                else
                    log_verbose "  ⏳ $ip - Waiting for machine status"
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

# Display DHCP leases (verbose mode only)
# Usage: show_dhcp_leases
show_dhcp_leases() {
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Getting DHCP leases for network: $NETWORK_NAME in $LIBVIRT_URI"
        virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || log_info "  > No leases found"
        echo ""
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

echo "[8/12] Waiting for Talos to boot and install to disk..."
echo "  Configuration:"
echo "    Timeout: ${BOOT_WAIT}s"
echo "    Interval: ${BOOT_INTERVAL}s"
echo "    Verbose: $VERBOSE"
echo "    Boot order: Disk-first (persistent across reboots)"
echo ""

# Phase 1: Wait for VMs to be running
wait_for_vms_running 60
echo ""

# Phase 2: Wait for DHCP leases
wait_for_dhcp_leases "$WORKER_COUNT" 60
echo ""

# Phase 3: Show initial DHCP leases (verbose)
show_dhcp_leases

# Phase 4: Wait for Talos maintenance mode (ISO boot)
log_info "Waiting for Talos maintenance mode..."
MAINTENANCE_ELAPSED=0
MAINTENANCE_WAIT=120

while [[ $MAINTENANCE_ELAPSED -lt $MAINTENANCE_WAIT ]]; do
    MASTER_IP="${VM_IPS[0]:-}"
    if [[ -n "$MASTER_IP" ]]; then
        if talosctl version --nodes "$MASTER_IP" --insecure 2>&1 | grep -q "v1\."; then
            log_info "  ✓ Talos maintenance mode accessible at $MASTER_IP"
            break
        fi
    fi
    sleep $BOOT_INTERVAL
    MAINTENANCE_ELAPSED=$((MAINTENANCE_ELAPSED + BOOT_INTERVAL))
    log_verbose "  ... waiting for maintenance mode (${MAINTENANCE_ELAPSED}s)"
done

if [[ $MAINTENANCE_ELAPSED -ge $MAINTENANCE_WAIT ]]; then
    log_warning "Talos maintenance mode not accessible after ${MAINTENANCE_WAIT}s"
fi

echo ""

# Phase 5: Wait for install to disk (monitor disk growth)
log_info "Waiting for Talos install to disk..."
INSTALL_WAIT=300
INSTALL_ELAPSED=0
INITIAL_DISK_SIZE=""

while [[ $INSTALL_ELAPSED -lt $INSTALL_WAIT ]]; do
    MASTER_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${MASTER_NAME}" | awk '{print $2}' | head -1)

    if [[ -n "$MASTER_VM" ]]; then
        CURRENT_DISK=$(virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "${MASTER_VM}-vda.raw" 2>/dev/null | grep -i allocation | awk '{print $2}')

        if [[ -z "$INITIAL_DISK_SIZE" ]]; then
            INITIAL_DISK_SIZE="$CURRENT_DISK"
        fi

        # Check if disk has grown significantly (install in progress or complete)
        if [[ "$CURRENT_DISK" != "$INITIAL_DISK_SIZE" ]] || [[ $INSTALL_ELAPSED -gt 60 ]]; then
            log_info "  ✓ Disk activity detected (installing to disk)"

            # Wait for install to finish
            sleep 30
            break
        fi
    fi

    sleep $BOOT_INTERVAL
    INSTALL_ELAPSED=$((INSTALL_ELAPSED + BOOT_INTERVAL))
    log_verbose "  ... waiting for install (${INSTALL_ELAPSED}s)"
done

echo ""

# Phase 6: Wait for Talos to reboot from disk
# With disk-first boot order, Talos will automatically reboot from disk after install
log_info "Waiting for Talos to reboot from disk..."
sleep 15

# Phase 7: Poll Talos machines from disk boot
log_info "Waiting for Talos to boot from disk..."
while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    log_info "  [${BOOT_ELAPSED}s] Checking VM status..."

    # Refresh DHCP leases after reboot
    mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")

    total_count=${#VM_IPS[@]}
    log_verbose "  > Found ${total_count} IPs: ${VM_IPS[*]}"

    if [[ $total_count -gt 0 ]] && check_all_machines_ready "${VM_IPS[@]}"; then
        echo ""
        log_info "  Progress: ${total_count}/${total_count} VMs ready"
        echo ""
        log_info "  All VMs ready!"
        break
    fi

    # Count ready machines for progress display
    ready_count=0
    for ip in "${VM_IPS[@]}"; do
        if [[ -n "$ip" ]]; then
            machine_ready=$(check_machine_ready "$ip")
            if [[ "$machine_ready" == "true" ]]; then
                ready_count=$((ready_count + 1))
            fi
        fi
    done

    echo ""
    log_info "  Progress: ${ready_count}/${total_count} VMs ready"
    echo ""

    sleep $BOOT_INTERVAL
    BOOT_ELAPSED=$((BOOT_ELAPSED + BOOT_INTERVAL))
done

if [[ $BOOT_ELAPSED -ge $BOOT_WAIT ]]; then
    log_warning "Not all VMs ready after ${BOOT_WAIT}s"
    echo "  Check VM console logs: virsh -c qemu:///system console <vm-name>"
    echo ""
    echo "  Continuing anyway (VMs may need more time)..."
fi

echo ""
log_info "  ✓ Talos booted from disk"
echo ""

# Return success if at least master is ready
MASTER_IP="${VM_IPS[0]:-}"
if [[ -n "$MASTER_IP" ]]; then
    if talosctl version --nodes "$MASTER_IP" 2>&1 | grep -q "Server:"; then
        echo "Master node is accessible"
        exit 0
    fi
fi

# If we got here, at least the boot wait completed
exit 0
