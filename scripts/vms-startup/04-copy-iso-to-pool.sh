#!/bin/bash
# Step 04: Copy ISO to storage pool
# Copies ISO to libvirt storage pool for VM access

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/11] Copying ISO to storage pool..."

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
        cp "$TALOS_IMAGE_PATH" "$POOL_PATH/$ISO_VOLUME_NAME"
        chmod 644 "$POOL_PATH/$ISO_VOLUME_NAME"
        virsh -c "$LIBVIRT_URI" pool-refresh "$STORAGE_POOL"
        echo "  ✓ ISO copied to storage pool"
    else
        echo "  WARNING: Could not get pool path, ISO will be used from local location"
    fi
fi
echo ""
