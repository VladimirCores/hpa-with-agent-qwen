#!/bin/bash
# Step 03: Prepare Talos raw disk image
# Downloads and decompresses the Talos raw image for direct disk usage

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[3/10] Preparing Talos raw disk image..."

# Check if using raw image mode
if [[ "${USE_RAW_IMAGE:-false}" != "true" ]]; then
    echo "  Raw image mode disabled, skipping..."
    echo ""
    exit 0
fi

# Check if raw image already exists
if [[ -f "$TALOS_RAW_IMAGE_PATH" ]]; then
    echo "  ✓ Talos raw image found: $TALOS_RAW_IMAGE_PATH"
    IMAGE_SIZE=$(ls -lh "$TALOS_RAW_IMAGE_PATH" | awk '{print $5}')
    echo "  Size: $IMAGE_SIZE"
    
    # Verify it's a valid disk image
    if file "$TALOS_RAW_IMAGE_PATH" | grep -q "QEMU"; then
        echo "  ✓ Valid QEMU disk image"
    elif file "$TALOS_RAW_IMAGE_PATH" | grep -q "x86 boot sector"; then
        echo "  ✓ Valid bootable disk image"
    else
        echo "  WARNING: Image type unknown, proceeding anyway"
    fi
    echo ""
    exit 0
fi

# Check if compressed image exists
if [[ -f "$TALOS_RAW_IMAGE_COMPRESSED" ]]; then
    echo "  Compressed image found: $TALOS_RAW_IMAGE_COMPRESSED"
else
    echo "  Downloading Talos raw image (compressed)..."
    echo "  URL: $TALOS_RAW_IMAGE_URL"
    
    # Download with progress
    if command -v wget &>/dev/null; then
        wget --show-progress -O "$TALOS_RAW_IMAGE_COMPRESSED" "$TALOS_RAW_IMAGE_URL"
    else
        curl -L -o "$TALOS_RAW_IMAGE_COMPRESSED" "$TALOS_RAW_IMAGE_URL"
    fi
    
    if [[ ! -f "$TALOS_RAW_IMAGE_COMPRESSED" ]]; then
        echo "ERROR: Failed to download Talos raw image"
        exit 1
    fi
    echo "  ✓ Download complete"
fi

# Check for zstd decompression tool
if ! command -v zstd &>/dev/null; then
    echo "ERROR: zstd not found. Please install it:"
    echo "  Ubuntu/Debian: sudo apt install zstd"
    echo "  Fedora/RHEL: sudo dnf install zstd"
    echo "  Arch: sudo pacman -S zstd"
    exit 1
fi

# Decompress the raw image
echo "  Decompressing raw image..."
zstd -d -c "$TALOS_RAW_IMAGE_COMPRESSED" > "$TALOS_RAW_IMAGE_PATH"

if [[ ! -f "$TALOS_RAW_IMAGE_PATH" ]]; then
    echo "ERROR: Failed to decompress raw image"
    exit 1
fi

# Verify the decompressed image
IMAGE_SIZE=$(ls -lh "$TALOS_RAW_IMAGE_PATH" | awk '{print $5}')
echo "  ✓ Decompressed: $IMAGE_SIZE"

# Convert to qcow2 format for better overlay support
QCOW2_PATH="${TALOS_RAW_IMAGE_PATH%.raw}.qcow2"
if [[ ! -f "$QCOW2_PATH" ]]; then
    echo "  Converting to qcow2 format for CoW overlays..."
    qemu-img convert -f raw -O qcow2 "$TALOS_RAW_IMAGE_PATH" "$QCOW2_PATH"
    
    if [[ -f "$QCOW2_PATH" ]]; then
        QCOW2_SIZE=$(ls -lh "$QCOW2_PATH" | awk '{print $5}')
        echo "  ✓ Created qcow2 base: $QCOW2_SIZE"
        # Update environment variable to use qcow2
        TALOS_RAW_IMAGE_PATH="$QCOW2_PATH"
    fi
fi

# Verify disk image
if file "$TALOS_RAW_IMAGE_PATH" | grep -qE "QEMU|x86 boot sector"; then
    echo "  ✓ Valid disk image verified"
else
    echo "  WARNING: Image verification inconclusive"
fi

echo ""
echo "  Raw image ready for VM provisioning"
echo ""
