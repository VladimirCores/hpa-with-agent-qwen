#!/bin/bash
# =============================================================================
# Create Talos Vagrant Box from ISO
# =============================================================================
# This script creates a reusable Vagrant box from the Talos ISO.
# NOTE: This is a complex operation. Consider using ISO boot instead.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env
set -a
source "$PROJECT_ROOT/.env" 2>/dev/null || true
set +a

BOX_NAME="${BOX_NAME:-talos}"
BOX_VERSION="${BOX_VERSION:-1.11.5}"
ISO_PATH="${PROJECT_ROOT}/metal-amd64.iso"

echo "=== Create Talos Vagrant Box ==="
echo ""
echo "Box: ${BOX_NAME} v${BOX_VERSION}"
echo "ISO: ${ISO_PATH}"
echo ""

# Check ISO exists
if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO not found. Download first:"
    echo "  curl -L -o ${ISO_PATH} https://github.com/siderolabs/talos/releases/download/v${BOX_VERSION}/metal-amd64.iso"
    exit 1
fi

echo "Creating a Vagrant box from Talos ISO is a manual process."
echo ""
echo "Recommended approach: Use ISO boot (default in Vagrantfile)"
echo ""
echo "If you need a box, follow these manual steps:"
echo ""
echo "1. Create a VM manually in virt-manager:"
echo "   - Boot from Talos ISO"
echo "   - Let Talos install to disk"
echo "   - Shutdown the VM"
echo ""
echo "2. Export the VM as a box:"
echo "   virsh dumpxml <vm-name> > domain.xml"
echo "   virt-sysprep -d <vm-name>"
echo ""
echo "3. Create box metadata:"
echo "   mkdir box-files && cd box-files"
echo "   cat > metadata.json <<EOF"
echo "   {"
echo "       \"name\": \"${BOX_NAME}\","
echo "       \"description\": \"Talos Linux ${BOX_VERSION}\","
echo "       \"version\": \"${BOX_VERSION}\","
echo "       \"provider\": \"libvirt\""
echo "   }"
echo "   EOF"
echo ""
echo "4. Package the box:"
echo "   tar czf ${BOX_NAME}.box metadata.json domain.xml"
echo ""
echo "5. Add to Vagrant:"
echo "   vagrant box add ${BOX_NAME} ${BOX_NAME}.box"
echo ""
echo "Alternatively, set USE_BOX=false in .env to use ISO boot (recommended)."
echo ""
