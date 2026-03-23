#!/bin/bash
# =============================================================================
# Create Talos Vagrant Box from ISO
# =============================================================================
# This script creates a reusable Vagrant box from the Talos ISO.
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
BOX_DIR="${PROJECT_ROOT}/box-${BOX_NAME}"
BOX_OUTPUT="${BOX_DIR}/${BOX_NAME}.box"

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

# Create box directory
mkdir -p "$BOX_DIR"

# Create metadata.json
cat > "${BOX_DIR}/metadata.json" <<EOF
{
    "name": "${BOX_NAME}",
    "description": "Talos Linux ${BOX_VERSION}",
    "version": "${BOX_VERSION}",
    "provider": "libvirt"
}
EOF

# Create minimal Vagrantfile for box
cat > "${BOX_DIR}/Vagrantfile" <<'EOF'
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "qemu"
  end
end
EOF

echo "Creating box from ISO..."
echo "This will take a few minutes..."
echo ""

# Create box using vagrant package with ISO
cd "$BOX_DIR"

# Create temporary VM to build box
cat > Vagrantfile.build <<VBFILE
Vagrant.configure("2") do |config|
  config.vm.box = "generic/empty"
  config.vm.provider :libvirt do |domain|
    domain.memory = 2048
    domain.cpus = 2
    domain.storage :file, device: :cdrom, path: "${ISO_PATH}"
    domain.boot 'cdrom'
    domain.boot 'hd'
    domain.storage :file, size: '5G', bus: 'virtio'
  end
end
VBFILE

echo "Step 1: Creating temporary VM..."
vagrant -f Vagrantfile.build up --provider=libvirt || true

echo ""
echo "Step 2: Waiting for Talos to boot (60 seconds)..."
sleep 60

echo ""
echo "Step 3: Stopping VM..."
vagrant -f Vagrantfile.build halt || true

echo ""
echo "Step 4: Packaging as box..."
vagrant -f Vagrantfile.build package --output "${BOX_NAME}.box"

echo ""
echo "Step 5: Adding box to Vagrant..."
vagrant box add "${BOX_NAME}" "${BOX_NAME}.box" --force

echo ""
echo "Step 6: Cleaning up..."
vagrant -f Vagrantfile.build destroy -f || true
rm -f Vagrantfile.build

echo ""
echo "=== Box Created ==="
echo ""
echo "Box name: ${BOX_NAME}"
echo "Box location: ${BOX_OUTPUT}"
echo ""
echo "To use this box in Vagrantfile:"
echo "  config.vm.box = \"${BOX_NAME}\""
echo ""
