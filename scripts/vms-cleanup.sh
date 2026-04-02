#!/bin/bash
# =============================================================================
# Cleanup Talos Cluster VMs
# =============================================================================
# This script stops and cleans up Talos cluster VMs and resources.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Parse arguments
DESTROY_NETWORK=false
FULL_CLEANUP=true  # Full cleanup is now default

while getopts "n" opt; do
    case $opt in
        n) DESTROY_NETWORK=true ;;
        *) echo "Usage: $0 [-n]"
           echo "  -n  Destroy network (default: preserve network)"
           exit 1 ;;
    esac
done

# If full cleanup is requested, enable all options
if [[ "$FULL_CLEANUP" == "true" ]]; then
    CLEAN_VOLUMES=true
    DESTROY_NETWORK=true
fi

echo "=== Talos Cluster VM Cleanup ==="
echo ""

# =============================================================================
# Step 1: Authenticate sudo (only for system mode)
# =============================================================================
SUDO_CACHE_FILE="$PROJECT_ROOT/.sudo_cache_$(whoami)"
SUDO_CACHE_DURATION=900  # 15 minutes in seconds

# Cleanup function
cleanup() {
    rm -f "$SUDO_CACHE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Only authenticate sudo for system mode (session mode doesn't need it)
IS_SESSION_MODE=false
if [[ "$LIBVIRT_URI" == "qemu:///session" ]]; then
    IS_SESSION_MODE=true
    echo "[1/7] Session mode detected - no sudo required"
    echo "  ✓ Running as user session"
else
    echo "[1/7] Authenticating sudo..."
    echo "  Sudo authentication required (cached during script run)..."
    sudo -v
    touch "$SUDO_CACHE_FILE"
    echo "  ✓ Sudo authenticated"
    
    # Fix .vagrant directory permissions BEFORE vagrant commands
    echo "  Fixing .vagrant permissions..."
    sudo chown -R "$(whoami)":"$(whoami)" "$(pwd)/.vagrant" 2>/dev/null || true
fi
echo ""

# =============================================================================
# Step 2: Check prerequisites
# =============================================================================
echo "[2/7] Checking prerequisites..."

# Check Vagrantfile exists
if [[ ! -f "$PROJECT_ROOT/Vagrantfile" ]]; then
    echo "WARNING: Vagrantfile not found in $PROJECT_ROOT"
fi
echo "  ✓ Vagrantfile checked"

# Check vagrant-libvirt plugin
if ! vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
    echo "WARNING: vagrant-libvirt plugin not installed"
else
    echo "  ✓ vagrant-libvirt plugin installed"
fi

# Check libvirt is running
if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    echo "  libvirtd not active, waiting for startup..."
    # Wait for libvirt to be ready (async startup)
    MAX_WAIT=30
    WAITED=0
    while ! virsh -c "$LIBVIRT_URI" list --all &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "WARNING: libvirtd not responding after ${MAX_WAIT}s"
            break
        fi
        sleep 1
        WAITED=$((WAITED + 1))
    done
    if (( WAITED < MAX_WAIT )); then
        echo "  ✓ libvirtd ready (${WAITED}s)"
    fi
else
    echo "  ✓ libvirtd service active"
fi
echo ""

# =============================================================================
# Step 3: Stop VMs with Vagrant
# =============================================================================
echo "[3/7] Stopping VMs with Vagrant..."

cd "$PROJECT_ROOT"

# Check if any VMs are managed by Vagrant
if vagrant status 2>/dev/null | grep -q "running"; then
    # Use halt instead of destroy to preserve disks
    echo "  Stopping VMs (preserving disks)..."
    vagrant halt
    echo "  ✓ VMs stopped"
else
    echo "  No running VMs found via Vagrant"
fi

# Force cleanup of any remaining VMs via virsh
echo "  Checking for remaining VMs..."
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    # Find VM with matching suffix (handles Vagrant prefix)
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$ACTUAL_VM" ]]; then
        echo "  Force stopping: $ACTUAL_VM"
        virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" --remove-all-storage 2>/dev/null || \
        virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" 2>/dev/null || true
    fi
done
echo "  ✓ All VMs stopped"
echo ""

# =============================================================================
# Step 4: Clean up volumes and storage pool
# =============================================================================
echo "[4/7] Cleaning up storage volumes..."

STORAGE_POOL="${STORAGE_POOL:-talos-pool}"

# Clean up raw image overlays (if using raw image mode)
if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    OVERLAY_DIR="$PROJECT_ROOT/.vagrant/raw-disks"
    if [[ -d "$OVERLAY_DIR" ]]; then
        echo "  Removing raw image overlays..."
        for overlay in "$OVERLAY_DIR"/*.qcow2; do
            if [[ -f "$overlay" ]]; then
                echo "    Removing: $(basename "$overlay")"
                rm -f "$overlay"
            fi
        done
        echo "  ✓ Raw image overlays removed"
    fi
fi

# Remove ALL volumes from talos-pool (ISO and VM disks)
echo "  Removing all volumes from $STORAGE_POOL..."
virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | while read -r vol rest; do
    [[ -z "$vol" ]] && continue
    echo "    Removing: $vol"
    virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null && \
        echo "      ✓ Removed" || echo "      ✗ Failed"
done

echo "  ✓ Volumes cleaned"

# If full cleanup, also remove the storage pool itself
if [[ "$FULL_CLEANUP" == "true" ]]; then
    echo "  Removing storage pool: $STORAGE_POOL..."
    if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
        virsh -c "$LIBVIRT_URI" pool-destroy "$STORAGE_POOL" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" pool-undefine "$STORAGE_POOL" 2>/dev/null || true
        echo "    ✓ Storage pool removed"
    fi

    # For project-local storage, clean up the directory
    if [[ "$POOL_PATH" == *".vagrant/storage-pool"* ]] || [[ "$POOL_PATH" == "$PROJECT_ROOT"* ]]; then
        POOL_PATH="${POOL_PATH/#\~/$HOME}"
        if [[ -d "$POOL_PATH" ]]; then
            echo "  Removing project-local storage directory: $POOL_PATH"
            rm -rf "$POOL_PATH"
            echo "    ✓ Project storage directory removed"
        fi
    # For session mode, also clean up the local directory
    elif [[ "$IS_SESSION_MODE" == "true" ]]; then
        POOL_PATH="${POOL_PATH:-$HOME/.local/share/libvirt/$STORAGE_POOL}"
        POOL_PATH="${POOL_PATH/#\~/$HOME}"
        if [[ -d "$POOL_PATH" ]]; then
            echo "  Removing session storage directory: $POOL_PATH"
            rm -rf "$POOL_PATH"
            echo "    ✓ Session storage directory removed"
        fi
    fi
fi

echo "  ✓ Storage cleanup complete"
echo ""

# =============================================================================
# Step 5: Destroy network (if -n or -f)
# =============================================================================
if [[ "$DESTROY_NETWORK" == "true" ]]; then
    echo "[5/7] Destroying network..."

    # Check if network exists
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
        echo "  Stopping network: $NETWORK_NAME"
        virsh -c "$LIBVIRT_URI" net-destroy "$NETWORK_NAME"

        echo "  Undefining network: $NETWORK_NAME"
        virsh -c "$LIBVIRT_URI" net-undefine "$NETWORK_NAME"

        # Remove bridge interface if it exists
        if ip link show "$BRIDGE_NAME" &>/dev/null; then
            echo "  Removing bridge interface: $BRIDGE_NAME"
            sudo ip link delete "$BRIDGE_NAME" 2>/dev/null || true
        fi

        echo "  ✓ Network destroyed"
    else
        echo "  Network '$NETWORK_NAME' does not exist"
    fi
else
    echo "[5/7] Skipping network cleanup (use -n to destroy network)"
fi
echo ""

# =============================================================================
# Step 6: Sudo cache (auto-cleaned on exit)
# =============================================================================
echo "[6/7] Sudo cache..."
echo "  ✓ Sudo cache will be cleaned up automatically"
echo ""

# =============================================================================
# Step 7: Summary
# =============================================================================
echo "[7/7] Cleanup Summary"
echo "==================="
echo "VMs: Stopped and undefined"
echo "Volumes: Cleaned"
if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    echo "Raw Image Overlays: Cleaned"
fi
if [[ "$DESTROY_NETWORK" == "true" ]]; then
    echo "Network: Destroyed"
else
    echo "Network: Preserved"
fi
echo "Storage Pool: Removed"
echo ""
echo "To restart the cluster:"
echo "  ./scripts/vms-startup.sh"
echo ""
if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    echo "Note: Raw image overlays will be recreated on next startup."
    echo "      Base image preserved: $TALOS_RAW_IMAGE_PATH"
else
    echo "Note: Storage pool was removed. It will be recreated on next startup."
fi
echo ""
echo "=== Cleanup Complete ==="
