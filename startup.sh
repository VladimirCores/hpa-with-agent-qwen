#!/bin/bash
# =============================================================================
# Unified Talos Cluster Startup Script
# =============================================================================
# This script orchestrates the entire cluster lifecycle:
# 1. Full Cleanup (remove orphaned libvirt resources)
# 2. Local Registry setup & population
# 3. VM Provisioning (vms-startup.sh)
# 4. Talos Bootstrap (talos-bootstrap.sh)
# 5. K8s Components (k8s-components.sh)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source shared logging library
source "$PROJECT_ROOT/scripts/logging.sh"

# Source .env file if it exists
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    log WARN ".env file not found in $PROJECT_ROOT. Using defaults."
fi

# Parse arguments
SKIP_REGISTRY=false
SKIP_VMS=false
SKIP_BOOTSTRAP=false
SKIP_COMPONENTS=false
FORCE_RESET=false
SKIP_CLEANUP=false

usage() {
    echo "Usage: $0 [options]"
    echo "  --skip-registry    Skip local registry setup and population"
    echo "  --skip-vms         Skip VM provisioning"
    echo "  --skip-bootstrap   Skip Talos cluster bootstrap"
    echo "  --skip-components  Skip K8s components installation (CNI, etc.)"
    echo "  --skip-cleanup     Skip orphaned resource cleanup"
    echo "  -f, --force-reset  Force reset (destroy VMs and disks, fresh start)"
    echo "  -h, --help         Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-registry)   SKIP_REGISTRY=true; shift ;;
        --skip-vms)        SKIP_VMS=true; shift ;;
        --skip-bootstrap)  SKIP_BOOTSTRAP=true; shift ;;
        --skip-components) SKIP_COMPONENTS=true; shift ;;
        --skip-cleanup)    SKIP_CLEANUP=true; shift ;;
        -f|--force-reset)  FORCE_RESET=true; shift ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1"; usage ;;
    esac
done

# =============================================================================
# Phase 0: Full Cleanup (Remove Orphaned Libvirt Resources)
# =============================================================================
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    log HEADER "Phase 0: Cleanup Orphaned Libvirt Resources"

    log DEBUG "Starting cleanup phase at $(date)"
    log DEBUG "PROJECT_ROOT: $PROJECT_ROOT"
    log DEBUG "LIBVIRT_URI: $LIBVIRT_URI"

    # VM name prefix (derived from project directory name, used by vagrant-libvirt)
    VM_PREFIX="$(basename "$PROJECT_ROOT")_"

    log DEBUG "VM_PREFIX: $VM_PREFIX"
    log DEBUG "MASTER_NAME: $MASTER_NAME"
    log DEBUG "WORKER_NAME_PREFIX: $WORKER_NAME_PREFIX"
    log DEBUG "WORKER_COUNT: $WORKER_COUNT"

    # Expected VM names
    EXPECTED_VMS=("$MASTER_NAME")
    for i in $(seq 1 "$WORKER_COUNT"); do
        EXPECTED_VMS+=("${WORKER_NAME_PREFIX}${i}")
    done

    log INFO "Scanning for orphaned VMs in libvirt..."
    log INFO "  Expected VMs: ${EXPECTED_VMS[*]}"
    log INFO "  VM Prefix: $VM_PREFIX"

    log DEBUG "Listing all VMs in libvirt..."
    virsh -c "$LIBVIRT_URI" list --all

    # Find and remove VMs that don't match expected names
    while read -r vm_name rest; do
        [[ -z "$vm_name" ]] && continue

        # Check if this VM belongs to our project (starts with VM_PREFIX)
        if [[ "$vm_name" == ${VM_PREFIX}* ]]; then
            # Extract the base name (without prefix)
            base_name="${vm_name#${VM_PREFIX}}"

            # Check if this is an expected VM
            is_expected=false
            for expected in "${EXPECTED_VMS[@]}"; do
                if [[ "$base_name" == "$expected" ]]; then
                    is_expected=true
                    break
                fi
            done

            # If not expected, it's orphaned - remove it
            if [[ "$is_expected" == "false" ]]; then
                log INFO "Found orphaned VM: $vm_name - removing..."
                vm_state=$(virsh -c "$LIBVIRT_URI" domstate "$vm_name" 2>/dev/null || echo "unknown")
                if [[ "$vm_state" == "running" ]]; then
                    virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true
                fi
                virsh -c "$LIBVIRT_URI" undefine "$vm_name" --remove-all-storage 2>/dev/null || \
                    virsh -c "$LIBVIRT_URI" undefine "$vm_name" 2>/dev/null || true
                log OK "Removed orphaned VM: $vm_name"
            else
                log INFO "Keeping expected VM: $vm_name"
            fi
        fi
    done < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | tail -n +3)

    log DEBUG "STORAGE_POOL: $STORAGE_POOL"
    log INFO "Cleaning up orphaned volumes..."
    STORAGE_POOL="${STORAGE_POOL:-talos-pool}"

    log DEBUG "Listing volumes in pool '$STORAGE_POOL'..."
    # Check if the storage pool exists before attempting to list volumes.
    # Avoids a silent crash with set -e when the pool hasn't been created yet
    # (e.g. first run, or after full cleanup).
    if ! virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
        log WARN "Storage pool '$STORAGE_POOL' does not exist yet. Skipping volume cleanup."
    else
        # Try to list volumes, handle polkit/auth issues gracefully
        # The "Authorization not available" warning is printed to stderr but command may still succeed
        VOL_LIST_OUTPUT=$(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>&1)
        echo "$VOL_LIST_OUTPUT"

        # List all volumes and remove those not belonging to expected VMs
        # Filter out header lines, separator lines, and authorization warnings
        # Only process actual volume names (alphanumeric with dots, underscores, hyphens)
    while read -r line; do
        # Skip authorization warnings
        [[ "$line" == *"Authorization"* ]] && continue
        # Skip header line (contains "Name" and "Path")
        [[ "$line" == *"Name"* ]] && [[ "$line" == *"Path"* ]] && continue
        # Skip separator lines (only dashes)
        [[ "$line" =~ ^[[:space:]]*-+[[:space:]]*$ ]] && continue
        # Skip empty lines
        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

        # Extract volume name (first field)
        vol=$(echo "$line" | awk '{print $1}')

        # Skip if volume name looks like a header word
        [[ "$vol" == "Name" ]] && continue
        [[ "$vol" == "Path" ]] && continue

        # Check if volume belongs to expected VMs or is the ISO
        is_expected=false
        if [[ "$vol" == *"talos-metal-amd64"* ]] || [[ "$vol" == *"metal-amd64.iso"* ]]; then
            is_expected=true
        fi

        for expected in "${EXPECTED_VMS[@]}"; do
            if [[ "$vol" == *"${VM_PREFIX}${expected}"* ]]; then
                is_expected=true
                break
            fi
        done

        if [[ "$is_expected" == "false" ]]; then
            log INFO "Removing orphaned volume: $vol"
            virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null && \
                log OK "Removed" || log ERROR "Failed to remove $vol"
        fi
    done < <(echo "$VOL_LIST_OUTPUT")
    fi  # end of pool-exists check

    log DEBUG "NETWORK_NAME: $NETWORK_NAME"
    log INFO "Checking for orphaned networks..."
    # Check if network exists but has no connected VMs
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
        log DEBUG "Network '$NETWORK_NAME' info:"
        virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME"
        active_vms=$(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -c "^[[:space:]]" || echo "0")
        log DEBUG "Active VMs in network: $active_vms"
        if [[ "$active_vms" -eq 0 ]]; then
            log INFO "Network '$NETWORK_NAME' exists but has no active VMs"
            log INFO "Preserving network for reuse"
        else
            log INFO "Network '$NETWORK_NAME' is active with $active_vms VM(s)"
        fi
    else
        log INFO "Network '$NETWORK_NAME' does not exist"
    fi

    log DEBUG "Cleanup phase completed at $(date)"
    log OK "Orphaned resource cleanup complete"
else
    log WARN "Phase 0: Skipping Orphaned Resource Cleanup"
fi

# =============================================================================
# Phase 1: Local Registry
# =============================================================================
if [[ "$SKIP_REGISTRY" != "true" ]]; then
    log HEADER "Phase 1: Local Registry Setup"

    log DEBUG "Starting Phase 1 at $(date)"

    log INFO "Starting local registry..."
    if ! "$PROJECT_ROOT/scripts/start-local-registry.sh"; then
        log ERROR "Failed to start local registry"
        exit 1
    fi

    log INFO "Populating local registry with images..."
    if ! "$PROJECT_ROOT/scripts/populate-local-registry.sh"; then
        log ERROR "Failed to populate local registry"
        exit 1
    fi

    log OK "Local registry ready"
    log DEBUG "Phase 1 completed at $(date)"
else
    log WARN "Phase 1: Skipping Local Registry Setup"
fi

# =============================================================================
# Phase 2: VM Provisioning
# =============================================================================
if [[ "$SKIP_VMS" != "true" ]]; then
    log HEADER "Phase 2: VM Provisioning"

    log DEBUG "Starting Phase 2 at $(date)"
    log DEBUG "FORCE_RESET: $FORCE_RESET"

    VMS_ARGS=""
    [[ "$FORCE_RESET" == "true" ]] && VMS_ARGS="-f"

    log DEBUG "Running vms-startup.sh with args: '$VMS_ARGS'"

    if ! "$PROJECT_ROOT/scripts/vms-startup.sh" $VMS_ARGS; then
        log ERROR "VM provisioning failed"
        exit 1
    fi
    log OK "VMs are up and running"
    log DEBUG "Phase 2 completed at $(date)"
else
    log WARN "Phase 2: Skipping VM Provisioning"
fi

# =============================================================================
# Phase 3: Talos Bootstrap
# =============================================================================
if [[ "$SKIP_BOOTSTRAP" != "true" ]]; then
    log HEADER "Phase 3: Talos Cluster Bootstrap"

    log DEBUG "Starting Phase 3 at $(date)"

    if ! "$PROJECT_ROOT/scripts/talos-bootstrap.sh"; then
        log ERROR "Talos bootstrap failed"
        exit 1
    fi
    log OK "Talos cluster bootstrapped"
    log DEBUG "Phase 3 completed at $(date)"
else
    log WARN "Phase 3: Skipping Talos Bootstrap"
fi

# =============================================================================
# Phase 4: K8s Components
# =============================================================================
if [[ "$SKIP_COMPONENTS" != "true" ]]; then
    log HEADER "Phase 4: Kubernetes Components (CNI, Metrics, MetalLB)"

    log DEBUG "Starting Phase 4 at $(date)"

    # Default to Cilium, Metrics Server, and MetalLB as they are standard for this project
    if ! "$PROJECT_ROOT/scripts/k8s-components.sh" --cni-cilium --with-metrics --with-metallb; then
        log ERROR "K8s components installation failed"
        exit 1
    fi
    log OK "Kubernetes components installed"
    log DEBUG "Phase 4 completed at $(date)"
else
    log WARN "Phase 4: Skipping Kubernetes Components"
fi

log HEADER "All Systems Operational"

log OK "Cluster is fully initialized and ready for use!"
log INFO ""
log INFO "Summary:"
log INFO "  - Cleanup:         Orphaned resources removed"
log INFO "  - Local Registry:  Running"
log INFO "  - VMs:             Running"
log INFO "  - Talos/K8s:       Bootstrapped"
log INFO "  - CNI:             Cilium"
log INFO "  - LoadBalancer:    MetalLB"
log INFO "  - Metrics:         metrics-server"
log INFO ""
log INFO "Verification:"
log INFO "  kubectl get nodes"
log INFO "  kubectl get pods -A"
