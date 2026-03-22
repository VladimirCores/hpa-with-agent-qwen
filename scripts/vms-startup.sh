#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
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
SKIP_CLEANUP=false
while getopts "s" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        *) echo "Usage: $0 [-s]"; echo "  -s  Skip cleanup (start without destroying existing VMs)"; exit 1 ;;
    esac
done

echo "=== Talos Cluster VM Startup ==="
echo ""

# =============================================================================
# Step 1: Authenticate sudo (local cache, cleaned up on exit)
# =============================================================================
SUDO_CACHE_FILE="$PROJECT_ROOT/.sudo_cache_$(whoami)"
SUDO_CACHE_DURATION=900  # 15 minutes in seconds

# Cleanup function
cleanup() {
    rm -f "$SUDO_CACHE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "[1/9] Authenticating sudo..."
echo "  Sudo authentication required (cached during script run)..."
sudo -v
touch "$SUDO_CACHE_FILE"
echo "  ✓ Sudo authenticated"

# Fix .vagrant directory permissions BEFORE vagrant commands
echo "  Fixing .vagrant permissions..."
sudo chown -R "$(whoami)":"$(whoami)" "$(pwd)/.vagrant" 2>/dev/null || true
echo ""

# =============================================================================
# Step 2: Check prerequisites
# =============================================================================
echo "[2/9] Checking prerequisites..."

# Check Vagrantfile exists
if [[ ! -f "$PROJECT_ROOT/Vagrantfile" ]]; then
    echo "ERROR: Vagrantfile not found in $PROJECT_ROOT"
    exit 1
fi
echo "  ✓ Vagrantfile found"

# Check vagrant-libvirt plugin
if ! vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
    echo "ERROR: vagrant-libvirt plugin not installed"
    echo "  Install with: vagrant plugin install vagrant-libvirt"
    exit 1
fi
echo "  ✓ vagrant-libvirt plugin installed"

# Check libvirt is running
if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    echo "  libvirtd not active, waiting for startup..."
    # Wait for libvirt to be ready (async startup)
    MAX_WAIT=30
    WAITED=0
    while ! virsh -c "$LIBVIRT_URI" list --all &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "ERROR: libvirtd not responding after ${MAX_WAIT}s"
            exit 1
        fi
        sleep 1
        WAITED=$((WAITED + 1))
    done
    echo "  ✓ libvirtd ready (${WAITED}s)"
else
    echo "  ✓ libvirtd service active"
fi
echo ""

# =============================================================================
# Step 3: Prepare ISO (check local or download)
# =============================================================================
echo "[3/9] Preparing Talos ISO image..."

TALOS_IMAGE_PATH="$PROJECT_ROOT/metal-amd64.iso"

if [[ -f "$TALOS_IMAGE_PATH" ]] && [[ -s "$TALOS_IMAGE_PATH" ]]; then
    echo "  ✓ Talos ISO found: $TALOS_IMAGE_PATH"
    ISO_SIZE=$(ls -lh "$TALOS_IMAGE_PATH" | awk '{print $5}')
    echo "  Size: $ISO_SIZE"
else
    if [[ -f "$TALOS_IMAGE_PATH" ]]; then
        echo "  WARNING: ISO file exists but is empty, re-downloading..."
        rm -f "$TALOS_IMAGE_PATH"
    fi
    echo "  Downloading Talos ISO..."
    curl -L -o "$TALOS_IMAGE_PATH" "$TALOS_IMAGE_URL"
    if [[ ! -f "$TALOS_IMAGE_PATH" ]] || [[ ! -s "$TALOS_IMAGE_PATH" ]]; then
        echo "ERROR: Failed to download Talos ISO"
        exit 1
    fi
    echo "  ✓ Download complete"
    ISO_SIZE=$(ls -lh "$TALOS_IMAGE_PATH" | awk '{print $5}')
    echo "  Size: $ISO_SIZE"
fi
echo ""

# =============================================================================
# Step 4: Copy ISO to storage pool
# =============================================================================
echo "[4/9] Copying ISO to storage pool..."

STORAGE_POOL="${STORAGE_POOL:-default}"
ISO_VOLUME_NAME="talos-metal-amd64.iso"

# Check if storage pool exists, create if needed
if ! virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
    echo "  Storage pool '$STORAGE_POOL' not found. Creating..."
    POOL_PATH="/var/lib/libvirt/$STORAGE_POOL"
    sudo mkdir -p "$POOL_PATH"
    sudo chmod 755 "$POOL_PATH"

    cat <<EOF | virsh -c "$LIBVIRT_URI" pool-define /dev/stdin
<pool type='dir'>
  <name>$STORAGE_POOL</name>
  <target>
    <path>$POOL_PATH</path>
  </target>
</pool>
EOF
    virsh -c "$LIBVIRT_URI" pool-start "$STORAGE_POOL"
    virsh -c "$LIBVIRT_URI" pool-autostart "$STORAGE_POOL"
    echo "  ✓ Storage pool created"
else
    echo "  ✓ Storage pool '$STORAGE_POOL' exists"
fi

# Copy ISO to storage pool if not already there
if virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$ISO_VOLUME_NAME" &>/dev/null; then
    echo "  ✓ ISO volume already exists in storage pool"
else
    echo "  Copying ISO to storage pool..."
    # Get pool path from pool-dumpxml
    POOL_PATH=$(virsh -c "$LIBVIRT_URI" pool-dumpxml "$STORAGE_POOL" | grep "<path>" | sed 's/.*<path>\(.*\)<\/path>.*/\1/')
    if [[ -n "$POOL_PATH" ]]; then
        sudo cp "$TALOS_IMAGE_PATH" "$POOL_PATH/$ISO_VOLUME_NAME"
        sudo chmod 644 "$POOL_PATH/$ISO_VOLUME_NAME"
        virsh -c "$LIBVIRT_URI" pool-refresh "$STORAGE_POOL"
        echo "  ✓ ISO copied to storage pool"
    else
        echo "  WARNING: Could not get pool path, ISO will be used from local location"
    fi
fi
echo ""

# =============================================================================
# Step 5: Set up network
# =============================================================================
echo "[5/9] Setting up network..."

if [[ -x "$SCRIPT_DIR/prepare-network.sh" ]]; then
    "$SCRIPT_DIR/prepare-network.sh"
else
    echo "ERROR: prepare-network.sh not found or not executable"
    exit 1
fi
echo ""

# =============================================================================
# Step 6: Clean up stale resources (optional)
# =============================================================================
if [[ "$SKIP_CLEANUP" == "false" ]]; then
    echo "[6/9] Cleaning up existing VMs..."

    # Destroy and undefine existing VMs
    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        if virsh -c "$LIBVIRT_URI" dominfo "$vm_name" &>/dev/null; then
            echo "  Destroying VM: $vm_name"
            virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true

            # Wait for VM to stop
            while virsh -c "$LIBVIRT_URI" dominfo "$vm_name" 2>/dev/null | grep -q "State:.*running"; do
                sleep 0.5
            done

            echo "  Undefining VM: $vm_name"
            virsh -c "$LIBVIRT_URI" undefine "$vm_name" --remove-all-storage 2>/dev/null || \
            virsh -c "$LIBVIRT_URI" undefine "$vm_name" 2>/dev/null || true
        fi
    done
    echo "  ✓ Cleanup complete"
else
    echo "[6/9] Skipping cleanup (using -s flag)"
fi
echo ""

# =============================================================================
# Step 7: Start all VMs with Vagrant
# =============================================================================
echo "[7/9] Starting VMs with Vagrant..."

cd "$PROJECT_ROOT"

if [[ "$SKIP_CLEANUP" == "false" ]]; then
    # Clean start - destroy and reload
    vagrant destroy -f 2>/dev/null || true
    vagrant up --provider=libvirt
else
    # Start existing VMs
    vagrant up --provider=libvirt
fi

if [[ $? -ne 0 ]]; then
    echo "ERROR: Vagrant failed to start VMs"
    exit 1
fi
echo "  ✓ VMs started"
echo ""

# =============================================================================
# Step 8: Verify deployment
# =============================================================================
echo "[8/9] Verifying deployment..."

sleep 5  # Give VMs time to boot

# Check VM status (handle Vagrant prefix)
echo "  VM Status:"
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    # Find VM with matching suffix (handles Vagrant prefix)
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1)
    if [[ -n "$ACTUAL_VM" ]]; then
        STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep "State:" | awk '{print $2}')
        echo "    - $ACTUAL_VM: $STATE"
    else
        echo "    - $vm_name: NOT FOUND"
    fi
done

# Check network leases
echo ""
echo "  DHCP Leases on $NETWORK_NAME:"
if virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" &>/dev/null; then
    virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" | head -20
else
    echo "    (No leases yet - VMs may still be booting)"
fi
echo ""

# =============================================================================
# Step 9: Summary
# =============================================================================
echo "[9/9] Startup Summary"
echo "==================="
echo "Cluster Name: Talos Cluster"
echo "Network: $NETWORK_NAME"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes (starting at $WORKER_IP_BASE)"
echo ""
echo "Next steps:"
echo "  1. Wait for Talos to boot (~30 seconds)"
echo "  2. Generate machine configurations:"
echo "     talosctl gen config ${CLUSTER_NAME:-talos-default} https://$MASTER_IP:6443"
echo "  3. Apply configurations with talosctl"
echo ""
echo "=== VM Startup Complete ==="
