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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source .env file if it exists
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo -e "${YELLOW}WARNING: .env file not found in $PROJECT_ROOT. Using defaults.${NC}"
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

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# Phase 0: Full Cleanup (Remove Orphaned Libvirt Resources)
# =============================================================================
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    print_header "Phase 0: Cleanup Orphaned Libvirt Resources"
    
    echo -e "${BLUE}[DEBUG] Starting cleanup phase at $(date)${NC}"
    echo -e "${BLUE}[DEBUG] PROJECT_ROOT: $PROJECT_ROOT${NC}"
    echo -e "${BLUE}[DEBUG] LIBVIRT_URI: $LIBVIRT_URI${NC}"

    # VM name prefix (derived from project directory name, used by vagrant-libvirt)
    VM_PREFIX="$(basename "$PROJECT_ROOT")_"
    
    echo -e "${BLUE}[DEBUG] VM_PREFIX: $VM_PREFIX${NC}"
    echo -e "${BLUE}[DEBUG] MASTER_NAME: $MASTER_NAME${NC}"
    echo -e "${BLUE}[DEBUG] WORKER_NAME_PREFIX: $WORKER_NAME_PREFIX${NC}"
    echo -e "${BLUE}[DEBUG] WORKER_COUNT: $WORKER_COUNT${NC}"

    # Expected VM names
    EXPECTED_VMS=("$MASTER_NAME")
    for i in $(seq 1 "$WORKER_COUNT"); do
        EXPECTED_VMS+=("${WORKER_NAME_PREFIX}${i}")
    done

    echo "Scanning for orphaned VMs in libvirt..."
    echo "  Expected VMs: ${EXPECTED_VMS[*]}"
    echo "  VM Prefix: $VM_PREFIX"
    echo ""

    echo -e "${BLUE}[DEBUG] Listing all VMs in libvirt...${NC}"
    virsh -c "$LIBVIRT_URI" list --all
    echo ""

    # Find and remove VMs that don't match expected names
    virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | tail -n +3 | while read -r vm_name rest; do
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
                echo "  Found orphaned VM: $vm_name - removing..."
                vm_state=$(virsh -c "$LIBVIRT_URI" domstate "$vm_name" 2>/dev/null || echo "unknown")
                if [[ "$vm_state" == "running" ]]; then
                    virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true
                fi
                virsh -c "$LIBVIRT_URI" undefine "$vm_name" --remove-all-storage 2>/dev/null || \
                    virsh -c "$LIBVIRT_URI" undefine "$vm_name" 2>/dev/null || true
                echo "    ✓ Removed orphaned VM: $vm_name"
            else
                echo "  Keeping expected VM: $vm_name"
            fi
        fi
    done

    echo ""
    echo -e "${BLUE}[DEBUG] STORAGE_POOL: $STORAGE_POOL${NC}"
    echo "Cleaning up orphaned volumes..."
    STORAGE_POOL="${STORAGE_POOL:-talos-pool}"

    echo -e "${BLUE}[DEBUG] Listing volumes in pool '$STORAGE_POOL'...${NC}"
    # Check if the storage pool exists before attempting to list volumes.
    # Avoids a silent crash with set -e when the pool hasn't been created yet
    # (e.g. first run, or after full cleanup).
    if ! virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
        echo -e "${YELLOW}  Storage pool '$STORAGE_POOL' does not exist yet. Skipping volume cleanup.${NC}"
    else
        # Try to list volumes, handle polkit/auth issues gracefully
        # The "Authorization not available" warning is printed to stderr but command may still succeed
        VOL_LIST_OUTPUT=$(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>&1)
        echo "$VOL_LIST_OUTPUT"
        echo ""

        # List all volumes and remove those not belonging to expected VMs
        # Filter out header lines, separator lines, and authorization warnings
        # Only process actual volume names (alphanumeric with dots, underscores, hyphens)
    echo "$VOL_LIST_OUTPUT" | while read -r line; do
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
            echo "  Removing orphaned volume: $vol"
            virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null && \
                echo "    ✓ Removed" || echo "    ✗ Failed"
        fi
    done
    fi  # end of pool-exists check

    echo ""
    echo -e "${BLUE}[DEBUG] NETWORK_NAME: $NETWORK_NAME${NC}"
    echo "Checking for orphaned networks..."
    # Check if network exists but has no connected VMs
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
        echo -e "${BLUE}[DEBUG] Network '$NETWORK_NAME' info:${NC}"
        virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME"
        active_vms=$(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -c "^[[:space:]]" || echo "0")
        echo -e "${BLUE}[DEBUG] Active VMs in network: $active_vms${NC}"
        if [[ "$active_vms" -eq 0 ]]; then
            echo "  Network '$NETWORK_NAME' exists but has no active VMs"
            echo "  Preserving network for reuse"
        else
            echo "  Network '$NETWORK_NAME' is active with $active_vms VM(s)"
        fi
    else
        echo "  Network '$NETWORK_NAME' does not exist"
    fi

    echo ""
    echo -e "${BLUE}[DEBUG] Cleanup phase completed at $(date)${NC}"
    echo -e "${GREEN}✓ Orphaned resource cleanup complete${NC}"
else
    echo -e "${YELLOW}Phase 0: Skipping Orphaned Resource Cleanup${NC}"
fi

# =============================================================================
# Phase 1: Local Registry
# =============================================================================
if [[ "$SKIP_REGISTRY" != "true" ]]; then
    print_header "Phase 1: Local Registry Setup"
    
    echo -e "${BLUE}[DEBUG] Starting Phase 1 at $(date)${NC}"

    echo "Starting local registry..."
    if ! "$PROJECT_ROOT/scripts/start-local-registry.sh"; then
        echo -e "${RED}ERROR: Failed to start local registry${NC}"
        exit 1
    fi

    echo "Populating local registry with images..."
    if ! "$PROJECT_ROOT/scripts/populate-local-registry.sh"; then
        echo -e "${RED}ERROR: Failed to populate local registry${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Local registry ready${NC}"
    echo -e "${BLUE}[DEBUG] Phase 1 completed at $(date)${NC}"
else
    echo -e "${YELLOW}Phase 1: Skipping Local Registry Setup${NC}"
fi

# =============================================================================
# Phase 2: VM Provisioning
# =============================================================================
if [[ "$SKIP_VMS" != "true" ]]; then
    print_header "Phase 2: VM Provisioning"
    
    echo -e "${BLUE}[DEBUG] Starting Phase 2 at $(date)${NC}"
    echo -e "${BLUE}[DEBUG] FORCE_RESET: $FORCE_RESET${NC}"

    VMS_ARGS=""
    [[ "$FORCE_RESET" == "true" ]] && VMS_ARGS="-f"
    
    echo -e "${BLUE}[DEBUG] Running vms-startup.sh with args: '$VMS_ARGS'${NC}"

    if ! "$PROJECT_ROOT/scripts/vms-startup.sh" $VMS_ARGS; then
        echo -e "${RED}ERROR: VM provisioning failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ VMs are up and running${NC}"
    echo -e "${BLUE}[DEBUG] Phase 2 completed at $(date)${NC}"
else
    echo -e "${YELLOW}Phase 2: Skipping VM Provisioning${NC}"
fi

# =============================================================================
# Phase 3: Talos Bootstrap
# =============================================================================
if [[ "$SKIP_BOOTSTRAP" != "true" ]]; then
    print_header "Phase 3: Talos Cluster Bootstrap"
    
    echo -e "${BLUE}[DEBUG] Starting Phase 3 at $(date)${NC}"

    if ! "$PROJECT_ROOT/scripts/talos-bootstrap.sh"; then
        echo -e "${RED}ERROR: Talos bootstrap failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Talos cluster bootstrapped${NC}"
    echo -e "${BLUE}[DEBUG] Phase 3 completed at $(date)${NC}"
else
    echo -e "${YELLOW}Phase 3: Skipping Talos Bootstrap${NC}"
fi

# =============================================================================
# Phase 4: K8s Components
# =============================================================================
if [[ "$SKIP_COMPONENTS" != "true" ]]; then
    print_header "Phase 4: Kubernetes Components (CNI, Metrics, MetalLB)"
    
    echo -e "${BLUE}[DEBUG] Starting Phase 4 at $(date)${NC}"

    # Default to Cilium, Metrics Server, and MetalLB as they are standard for this project
    if ! "$PROJECT_ROOT/scripts/k8s-components.sh" --cni-cilium --with-metrics --with-metallb; then
        echo -e "${RED}ERROR: K8s components installation failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Kubernetes components installed${NC}"
    echo -e "${BLUE}[DEBUG] Phase 4 completed at $(date)${NC}"
else
    echo -e "${YELLOW}Phase 4: Skipping Kubernetes Components${NC}"
fi

print_header "All Systems Operational"

echo -e "${GREEN}Cluster is fully initialized and ready for use!${NC}"
echo ""
echo "Summary:"
echo "  - Cleanup:         Orphaned resources removed"
echo "  - Local Registry:  Running"
echo "  - VMs:             Running"
echo "  - Talos/K8s:       Bootstrapped"
echo "  - CNI:             Cilium"
echo "  - LoadBalancer:    MetalLB"
echo "  - Metrics:         metrics-server"
echo ""
echo "Verification:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""
