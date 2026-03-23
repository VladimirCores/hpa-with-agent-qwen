#!/bin/bash
# Step 05: Set up network
# Runs prepare-network.sh to create/update libvirt network

echo "[5/11] Setting up network..."

if [[ -x "$SCRIPT_DIR/prepare-network.sh" ]]; then
    "$SCRIPT_DIR/prepare-network.sh"
else
    echo "ERROR: prepare-network.sh not found or not executable"
    exit 1
fi
echo ""
