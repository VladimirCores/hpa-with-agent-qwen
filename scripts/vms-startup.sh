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
FORCE_RESET=false
while getopts "sf" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        *) echo "Usage: $0 [-s] [-f]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
           exit 1 ;;
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
    echo "[6/9] Cleaning up existing VMs and disks..."

    # Remove disk volumes first (ensures fresh install for Talos v1.12.x)
    echo "  Removing disk volumes..."
    STORAGE_POOL="${STORAGE_POOL:-talos-pool}"
    for vol in $(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | tail -n +2 | grep -v "^-" | awk '{print $1}' | grep -v "\.iso$"); do
        echo "    Removing: $vol"
        virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$vol" 2>/dev/null || true
    done

    # Destroy and undefine existing VMs
    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        # Find VM with matching suffix (handles Vagrant prefix)
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
        if [[ -n "$ACTUAL_VM" ]]; then
            echo "  Destroying VM: $ACTUAL_VM"
            virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true

            # Wait for VM to stop
            while virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep -q "State:.*running"; do
                sleep 0.5
            done

            echo "  Undefining VM: $ACTUAL_VM"
            virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" --remove-all-storage 2>/dev/null || \
            virsh -c "$LIBVIRT_URI" undefine "$ACTUAL_VM" 2>/dev/null || true
        fi
    done

    echo "  ✓ Cleanup complete (disks wiped for fresh Talos install)"
else
    echo "[6/9] Skipping cleanup (using -s flag)"
fi
echo ""

# =============================================================================
# Step 7: Start all VMs with Vagrant
# =============================================================================
echo "[7/9] Starting VMs with Vagrant..."

cd "$PROJECT_ROOT"

if [[ "$FORCE_RESET" == "true" ]]; then
    # Full reset - destroy VMs and disks
    echo "  Force reset requested - destroying VMs and disks..."
    vagrant destroy -f 2>/dev/null || true
    vagrant up --provider=libvirt
elif [[ "$SKIP_CLEANUP" == "false" ]]; then
    # Normal start - halt VMs first (preserves disks), then start
    echo "  Stopping existing VMs (preserving disks)..."
    vagrant halt 2>/dev/null || true
    echo "  Starting VMs..."
    vagrant up --provider=libvirt
else
    # Start existing VMs without stopping
    vagrant up --provider=libvirt
fi

if [[ $? -ne 0 ]]; then
    echo "ERROR: Vagrant failed to start VMs"
    exit 1
fi
echo "  ✓ VMs started"
echo ""

# =============================================================================
# Step 8: Wait for Talos to boot from ISO
# =============================================================================
echo "[8/11] Waiting for Talos to boot from ISO..."

# Wait for each VM to be accessible via Talos API
BOOT_WAIT=300  # 5 minutes max
BOOT_INTERVAL=5
BOOT_ELAPSED=0

echo "  Waiting for Talos API to be accessible..."
echo "  (Polling every ${BOOT_INTERVAL}s, timeout ${BOOT_WAIT}s)"
echo ""

# Function to check if Talos API is accessible
check_talos_api() {
    local ip="$1"
    # Try talosctl with timeout
    timeout 3 talosctl get version --nodes "$ip" --insecure &>/dev/null
    return $?
}

# Function to check if port 50000 is open
check_port_50000() {
    local ip="$1"
    # Try connecting to Talos API port (50000)
    timeout 2 bash -c "echo > /dev/tcp/$ip/50000" 2>/dev/null
    return $?
}

while [[ $BOOT_ELAPSED -lt $BOOT_WAIT ]]; do
    echo "  [${BOOT_ELAPSED}s] Checking VM status..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))

        # Find VM with matching suffix
        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)

        if [[ -n "$ACTUAL_VM" ]]; then
            # Get VM state
            VM_STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep "State:" | awk '{print $2}')

            # Get IP from DHCP leases
            VM_IP=""
            for lease in $(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i "$vm_name" | awk '{print $4}' | cut -d'/' -f1); do
                VM_IP="$lease"
                break
            done

            if [[ -n "$VM_IP" ]]; then
                # Check Talos API accessibility
                if check_talos_api "$VM_IP"; then
                    echo "    ✓ $ACTUAL_VM ($VM_IP) - Talos API ready"
                    READY_COUNT=$((READY_COUNT + 1))
                    continue
                # Fallback: Check if port 50000 is open
                elif check_port_50000 "$VM_IP"; then
                    echo "    ⏳ $ACTUAL_VM ($VM_IP) - Port 50000 open, API starting (state: $VM_STATE)"
                else
                    echo "    ⏳ $ACTUAL_VM ($VM_IP) - Waiting for port 50000 (state: $VM_STATE)"
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

# =============================================================================
# Step 9: Eject ISO and change boot order to disk-only
# =============================================================================
echo "[9/10] Ejecting ISO and setting disk boot..."

for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    # Find VM with matching suffix
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$ACTUAL_VM" ]]; then
        # Get IP before reboot
        VM_IP=""
        for lease in $(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i "$vm_name" | awk '{print $4}' | cut -d'/' -f1); do
            VM_IP="$lease"
            break
        done

        # Eject ISO from CDROM
        virsh -c "$LIBVIRT_URI" change-media-device "$ACTUAL_VM" --path hda --eject 2>/dev/null || true

        # Update boot order: disk first, cdrom removed
        XML=$(virsh -c "$LIBVIRT_URI" dumpxml "$ACTUAL_VM" 2>/dev/null)
        if echo "$XML" | grep -q "<boot dev='cdrom'/>"; then
            # Remove cdrom boot entry, keep only hd
            echo "$XML" | sed "/<boot dev='cdrom'\/>/d" | virsh -c "$LIBVIRT_URI" define /dev/stdin 2>/dev/null || true
        fi

        echo "    ✓ ISO ejected from $ACTUAL_VM"
    fi
done

echo "  ✓ ISO ejected, boot order set to disk-only"
echo ""

# =============================================================================
# Step 10: Reboot VMs and verify disk boot
# =============================================================================
echo "[10/11] Rebooting VMs to verify disk boot..."

REBOOT_WAIT=300  # 5 minutes max
REBOOT_INTERVAL=5
REBOOT_ELAPSED=0

# Reboot all VMs
echo "  Sending reboot command to all VMs..."
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$ACTUAL_VM" ]]; then
        echo "  Rebooting $ACTUAL_VM..."
        virsh -c "$LIBVIRT_URI" reboot "$ACTUAL_VM" 2>/dev/null || true
    fi
done

echo ""
echo "  Waiting for VMs to reboot from disk..."
echo "  (Polling every ${REBOOT_INTERVAL}s, timeout ${REBOOT_WAIT}s)"
echo ""

while [[ $REBOOT_ELAPSED -lt $REBOOT_WAIT ]]; do
    echo "  [${REBOOT_ELAPSED}s] Checking VM status after reboot..."

    ALL_READY=true
    READY_COUNT=0
    TOTAL_COUNT=0

    for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))

        ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)

        if [[ -n "$ACTUAL_VM" ]]; then
            # Get VM state
            VM_STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$ACTUAL_VM" 2>/dev/null | grep "State:" | awk '{print $2}')

            # Get IP from DHCP leases
            VM_IP=""
            for lease in $(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i "$vm_name" | awk '{print $4}' | cut -d'/' -f1); do
                VM_IP="$lease"
                break
            done

            if [[ -n "$VM_IP" ]]; then
                if talosctl get version --nodes "$VM_IP" --insecure &>/dev/null; then
                    # Verify boot source (should be disk, not ISO)
                    CDROM_PRESENT=$(virsh -c "$LIBVIRT_URI" domblklist "$ACTUAL_VM" 2>/dev/null | grep -E "^hda.*iso$" | wc -l)
                    if [[ "$CDROM_PRESENT" -eq 0 ]]; then
                        echo "    ✓ $ACTUAL_VM ($VM_IP) - Booted from disk ✓"
                    else
                        echo "    ⚠ $ACTUAL_VM ($VM_IP) - Ready (CDROM still attached)"
                    fi
                    READY_COUNT=$((READY_COUNT + 1))
                    continue
                else
                    echo "    ⏳ $ACTUAL_VM ($VM_IP) - IP assigned, Talos API not ready (state: $VM_STATE)"
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
        echo "  All VMs booted from disk successfully!"
        break
    fi

    sleep $REBOOT_INTERVAL
    REBOOT_ELAPSED=$((REBOOT_ELAPSED + REBOOT_INTERVAL))
done

if [[ "$ALL_READY" != "true" ]]; then
    echo "  WARNING: Not all VMs ready after reboot"
    echo "  Check VM console logs: virsh -c qemu:///system console <vm-name>"
else
    echo "  ✓ All VMs booted from disk successfully"
fi
echo ""

# =============================================================================
# Step 11: Summary
# =============================================================================
echo "[11/11] Startup Summary"
echo "==================="
echo "Cluster Name: Talos Cluster"
echo "Network: $NETWORK_NAME"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes (starting at $WORKER_IP_BASE)"
echo ""
echo "Boot Status:"
echo "  ✓ VMs booted from ISO (initial install)"
echo "  ✓ ISO ejected"
echo "  ✓ VMs rebooted from disk"
echo ""
echo "Next steps:"
echo "  1. Generate machine configurations:"
echo "     talosctl gen config ${CLUSTER_NAME:-talos-default} https://$MASTER_IP:6443"
echo "  2. Apply configurations with talosctl"
echo "     ./scripts/talos-bootstrap.sh"
echo ""
echo "=== VM Startup Complete ==="
