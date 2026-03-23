#!/bin/bash
# Step 03: Prepare Talos ISO image
# Checks if ISO exists or downloads it

echo "[3/11] Preparing Talos ISO image..."

if [[ -f "$TALOS_IMAGE_PATH" ]]; then
    echo "  ✓ Talos ISO found: $TALOS_IMAGE_PATH"
    ISO_SIZE=$(ls -lh "$TALOS_IMAGE_PATH" | awk '{print $5}')
    echo "  Size: $ISO_SIZE"
else
    echo "  Downloading Talos ISO..."
    curl -L -o "$TALOS_IMAGE_PATH" "$TALOS_IMAGE_URL"
    if [[ ! -f "$TALOS_IMAGE_PATH" ]]; then
        echo "ERROR: Failed to download Talos ISO"
        exit 1
    fi
    echo "  ✓ Download complete"
fi
echo ""
