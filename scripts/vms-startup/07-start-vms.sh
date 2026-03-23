#!/bin/bash
# Step 07: Start all VMs with Vagrant
# Starts VMs using Vagrant with libvirt provider

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[7/11] Starting VMs with Vagrant..."

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
