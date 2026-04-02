#!/bin/bash
# Step 05: Set up network
# Runs prepare-network.sh to create/update libvirt network

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[5/11] Setting up network..."

if [[ -x "$SCRIPT_DIR/prepare-network.sh" ]]; then
    # Pass LIBVIRT_URI to prepare-network.sh
    LIBVIRT_URI="$LIBVIRT_URI" "$SCRIPT_DIR/prepare-network.sh"
else
    echo "ERROR: prepare-network.sh not found or not executable"
    exit 1
fi
echo ""
