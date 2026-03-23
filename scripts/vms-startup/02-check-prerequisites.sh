#!/bin/bash
# Step 02: Check prerequisites
# Verifies Vagrantfile, vagrant-libvirt plugin, and libvirtd

echo "[2/11] Checking prerequisites..."

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
