#!/bin/bash
# =============================================================================
# Step 04: Create libvirt storage pool
# =============================================================================
# Creates the storage pool if it doesn't exist.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/12] Creating storage pool..."
echo "  Pool name: $STORAGE_POOL"
echo "  Pool path: $POOL_PATH"
echo "  Libvirt URI: $LIBVIRT_URI"
echo ""

# Determine if using project-local storage
IS_PROJECT_LOCAL=false
if [[ "$POOL_PATH" == *".vagrant/storage-pool"* ]] || [[ "$POOL_PATH" == "$PROJECT_ROOT"* ]]; then
    IS_PROJECT_LOCAL=true
    echo "  Using project-local storage (portable, no sudo needed)"
fi

# Expand ~ to home directory if needed
POOL_PATH="${POOL_PATH/#\~/$HOME}"

# Check if storage pool exists
if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" &>/dev/null; then
    echo "  ✓ Storage pool '$STORAGE_POOL' already exists"
    
    # Verify pool path
    ACTUAL_PATH=$(virsh -c "$LIBVIRT_URI" pool-dumpxml "$STORAGE_POOL" 2>/dev/null | grep "<path>" | sed 's/.*<path>\(.*\)<\/path>.*/\1/')
    if [[ "$ACTUAL_PATH" == "$POOL_PATH" ]]; then
        echo "  ✓ Pool path matches: $POOL_PATH"
    else
        echo "  WARNING: Pool path mismatch"
        echo "    Expected: $POOL_PATH"
        echo "    Actual: $ACTUAL_PATH"
    fi
else
    echo "  Storage pool not found, creating..."
    
    # Create pool directory
    echo "    Creating directory: $POOL_PATH"
    if [[ "$IS_PROJECT_LOCAL" == "true" ]]; then
        mkdir -p "$POOL_PATH"
        chmod 755 "$POOL_PATH"
    else
        run_sudo mkdir -p "$POOL_PATH"
        run_sudo chown qemu:kvm "$POOL_PATH"
        run_sudo chmod 755 "$POOL_PATH"
    fi
    
    # Create pool XML
    echo "    Defining storage pool..."
    POOL_XML=$(cat <<EOF
<pool type='dir'>
  <name>$STORAGE_POOL</name>
  <target>
    <path>$POOL_PATH</path>
  </target>
</pool>
EOF
)
    echo "$POOL_XML" | virsh -c "$LIBVIRT_URI" pool-define /dev/stdin >/dev/null
    virsh -c "$LIBVIRT_URI" pool-start "$STORAGE_POOL" >/dev/null
    virsh -c "$LIBVIRT_URI" pool-autostart "$STORAGE_POOL" >/dev/null
    
    echo "  ✓ Storage pool created at $POOL_PATH"
fi

# Verify pool is active
if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" 2>/dev/null | grep -qi "running"; then
    POOL_INFO=$(virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" 2>/dev/null)
    CAPACITY=$(echo "$POOL_INFO" | grep "Capacity:" | awk '{print $2, $3}')
    ALLOCATION=$(echo "$POOL_INFO" | grep "Allocation:" | awk '{print $2, $3}')
    AVAILABLE=$(echo "$POOL_INFO" | grep "Available:" | awk '{print $2, $3}')
    
    echo "  ✓ Storage pool is active"
    echo "    Capacity: $CAPACITY, Allocation: $ALLOCATION, Available: $AVAILABLE"
else
    echo "  ERROR: Storage pool is not active"
    echo "  Pool state:"
    virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" 2>/dev/null || echo "  (cannot query pool)"
    exit 1
fi

echo ""
