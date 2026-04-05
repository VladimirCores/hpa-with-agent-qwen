#!/bin/bash
# Step 07: Replace VM disk volumes with CoW overlays from raw image
# Stops VMs, replaces disks with CoW overlays, then restarts VMs

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# VM name prefix (derived from project directory name)
VM_PREFIX="$(basename "$(dirname "$(dirname "$STEP_DIR")")")_"

echo "[7/10] Replacing VM disks with CoW overlays..."

# Check if using raw image mode
if [[ "${USE_RAW_IMAGE:-false}" != "true" ]]; then
    echo "  Raw image mode disabled, skipping..."
    echo ""
    exit 0
fi

# Verify raw image exists
if [[ ! -f "$TALOS_RAW_IMAGE_PATH" ]]; then
    echo "ERROR: Raw image not found: $TALOS_RAW_IMAGE_PATH"
    echo "  Run step 03 first: ./vms-startup/03-prepare-raw-image.sh"
    exit 1
fi

# Determine base image format
BASE_IMAGE="$TALOS_RAW_IMAGE_PATH"
if [[ -f "${TALOS_RAW_IMAGE_PATH%.raw}.qcow2" ]]; then
    BASE_IMAGE="${TALOS_RAW_IMAGE_PATH%.raw}.qcow2"
    echo "  Using qcow2 base image: $BASE_IMAGE"
fi

# Ensure storage pool exists, create if needed
if ! virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
    echo "  Storage pool '$STORAGE_POOL' not found. Creating..."
    
    # Use POOL_PATH from .env or default to /var/lib/libvirt/$STORAGE_POOL
    POOL_PATH="${POOL_PATH:-/var/lib/libvirt/$STORAGE_POOL}"
    # Expand ~ to home directory if needed
    POOL_PATH="${POOL_PATH/#\~/$HOME}"
    
    # Create pool directory
    sudo mkdir -p "$POOL_PATH"
    sudo chown qemu:kvm "$POOL_PATH"
    sudo chmod 755 "$POOL_PATH"
    
    # Create pool XML
    POOL_XML=$(cat <<EOF
<pool type='dir'>
  <name>$STORAGE_POOL</name>
  <target>
    <path>$POOL_PATH</path>
  </target>
</pool>
EOF
)
    
    # Define and start the pool
    echo "$POOL_XML" | virsh -c "$LIBVIRT_URI" pool-define /dev/stdin
    virsh -c "$LIBVIRT_URI" pool-start "$STORAGE_POOL"
    virsh -c "$LIBVIRT_URI" pool-autostart "$STORAGE_POOL"
    echo "  ✓ Storage pool created"
else
    echo "  ✓ Storage pool '$STORAGE_POOL' exists"
fi

# Get pool path
POOL_PATH=$(virsh -c "$LIBVIRT_URI" pool-dumpxml "$STORAGE_POOL" 2>/dev/null | grep "<path>" | sed 's/.*<path>\(.*\)<\/path>.*/\1/')
if [[ -z "$POOL_PATH" ]]; then
    echo "ERROR: Could not determine storage pool path"
    exit 1
fi

# Create base image volume in pool (if not exists)
BASE_VOLUME_NAME="talos-base-image.qcow2"
if ! virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$BASE_VOLUME_NAME" &>/dev/null; then
    echo "  Creating base image volume in pool..."
    sudo cp "$BASE_IMAGE" "$POOL_PATH/$BASE_VOLUME_NAME"
    sudo chmod 644 "$POOL_PATH/$BASE_VOLUME_NAME"
    virsh -c "$LIBVIRT_URI" pool-refresh "$STORAGE_POOL"
    echo "  ✓ Base image volume created"
else
    echo "  ✓ Base image volume exists"
fi

# Function to replace volume with CoW overlay
replace_with_overlay() {
    local vm_name="$1"
    local volume_name="${VM_PREFIX}${vm_name}-vda.qcow2"
    local volume_path="$POOL_PATH/$volume_name"
    local temp_path="$POOL_PATH/${volume_name}.tmp"
    
    # Determine disk size based on VM role
    local disk_size_gb
    if [[ "$vm_name" == "$MASTER_NAME" ]]; then
        disk_size_gb="${MASTER_DISK:-50}"
    else
        disk_size_gb="${WORKER_DISK:-20}"
    fi

    # Check if volume exists
    if ! virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$volume_name" &>/dev/null; then
        echo "  Volume not found: $vm_name"
        return 1
    fi

    # Get volume info to check if it's already an overlay
    vol_info=$(virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$volume_name" 2>/dev/null)
    if echo "$vol_info" | grep -q "Backing file.*talos-base-image"; then
        echo "  ✓ Already a CoW overlay: $vm_name"
        # Check if resize is needed
        local current_size=$(echo "$vol_info" | grep "Capacity:" | awk '{print $2}' | sed 's/GiB//')
        if (( $(echo "$current_size < $disk_size_gb" | bc -l 2>/dev/null || echo 0) )); then
            echo "  Resizing disk from ${current_size}GiB to ${disk_size_gb}GiB..."
            sudo qemu-img resize "$volume_path" "${disk_size_gb}G" >/dev/null 2>&1
            echo "  ✓ Disk resized"
        fi
        return 0
    fi

    echo "  Replacing with CoW overlay: $vm_name (size: ${disk_size_gb}G)"

    # Move existing volume to temp
    sudo mv "$volume_path" "$temp_path"

    # Create CoW overlay with correct virtual size
    sudo qemu-img create -f qcow2 -F qcow2 -b "$POOL_PATH/$BASE_VOLUME_NAME" "$volume_path" "${disk_size_gb}G" >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        sudo chown qemu:kvm "$volume_path"
        sudo chmod 644 "$volume_path"
        sudo rm -f "$temp_path"
        virsh -c "$LIBVIRT_URI" pool-refresh "$STORAGE_POOL" >/dev/null 2>&1
        echo "  ✓ Created CoW overlay: $volume_name"
    else
        echo "  ERROR: Failed to create overlay, restoring..."
        sudo mv "$temp_path" "$volume_path"
        return 1
    fi
}

# Stop all VMs before replacing disks
echo ""
echo "  Stopping VMs for disk replacement..."
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${VM_PREFIX}${vm_name}" | awk '{print $2}' | head -1)
    if [[ -n "$ACTUAL_VM" ]]; then
        echo "    Stopping: $ACTUAL_VM"
        virsh -c "$LIBVIRT_URI" destroy "$ACTUAL_VM" 2>/dev/null || true
    fi
done

# Wait for VMs to stop
sleep 3

# Replace volumes for all VMs with CoW overlays
echo ""
echo "  Creating CoW overlays..."
replace_with_overlay "$MASTER_NAME"
for i in $(seq 1 "$WORKER_COUNT"); do
    replace_with_overlay "${WORKER_NAME_PREFIX}${i}"
done

# Start VMs after disk replacement
echo ""
echo "  Starting VMs with CoW overlay disks..."
cd "$PROJECT_ROOT"
vagrant up --provider=libvirt 2>&1 | tail -20

# Verify overlays
echo ""
echo "  Disk volumes in pool:"
virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" 2>/dev/null | grep -E "\.qcow2" | while read -r line; do
    echo "    $line"
done

echo ""
echo "  ✓ VM disk volumes ready (CoW overlays)"
echo ""
