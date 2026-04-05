#!/bin/bash
# Step 04: Create libvirt storage pool
# Creates the storage pool if it doesn't exist (for both ISO and raw image modes)
# Supports both system mode (qemu:///system) and session mode (qemu:///session)
# Default: project-local storage (portable, no sudo required)

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/12] Creating storage pool..."

# Determine if using project-local storage
IS_PROJECT_LOCAL=false
if [[ "$POOL_PATH" == *".vagrant/storage-pool"* ]] || [[ "$POOL_PATH" == "$PROJECT_ROOT"* ]]; then
    IS_PROJECT_LOCAL=true
fi

# Expand ~ to home directory if needed
POOL_PATH="${POOL_PATH/#\~/$HOME}"

# Check if storage pool exists, create if needed
if ! virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
    echo "  Storage pool '$STORAGE_POOL' not found. Creating..."

    # Create pool directory
    if [[ "$IS_PROJECT_LOCAL" == "true" ]]; then
        # Project-local storage: no sudo needed, user owns the directory
        mkdir -p "$POOL_PATH"
        chmod 755 "$POOL_PATH"
        echo "  Using project-local storage: $POOL_PATH"
    elif [[ "$LIBVIRT_URI" == "qemu:///session" ]]; then
        # Session mode: use user's local libvirt storage
        mkdir -p "$POOL_PATH"
        chmod 755 "$POOL_PATH"
        echo "  Using session storage: $POOL_PATH"
    else
        # System mode: requires sudo
        sudo mkdir -p "$POOL_PATH"
        sudo chown qemu:kvm "$POOL_PATH"
        sudo chmod 755 "$POOL_PATH"
        echo "  Using system storage: $POOL_PATH"
    fi

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
    echo "  ✓ Storage pool created at $POOL_PATH"
else
    echo "  ✓ Storage pool '$STORAGE_POOL' exists"

    # Verify pool path matches expected
    ACTUAL_PATH=$(virsh -c "$LIBVIRT_URI" pool-dumpxml "$STORAGE_POOL" 2>/dev/null | grep "<path>" | sed 's/.*<path>\(.*\)<\/path>.*/\1/')
    if [[ "$ACTUAL_PATH" != "$POOL_PATH" ]]; then
        echo "  WARNING: Pool path mismatch"
        echo "    Expected: $POOL_PATH"
        echo "    Actual: $ACTUAL_PATH"
    fi
fi

# Verify pool is active
if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" 2>/dev/null | grep -qi "running"; then
    echo "  ✓ Storage pool is active"
else
    echo "  ERROR: Storage pool is not active"
    exit 1
fi

echo ""
