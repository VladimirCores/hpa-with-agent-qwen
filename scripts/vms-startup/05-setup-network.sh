#!/bin/bash
# =============================================================================
# Step 05: Setup Network
# =============================================================================
# Creates or updates libvirt network for Talos cluster
# Returns: 0 on success, 1 on failure
# =============================================================================

set -euo pipefail

# Get script directory
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$STEP_DIR")")"
SCRIPT_DIR="$PROJECT_ROOT/scripts"

# Source common setup (but preserve SCRIPT_DIR)
export SCRIPT_DIR
source "$STEP_DIR/00-setup.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Setting up network..."
echo ""

# Check prepare-network.sh exists
if [[ ! -x "$SCRIPT_DIR/prepare-network.sh" ]]; then
    echo -e "${RED}ERROR: prepare-network.sh not found or not executable${NC}"
    exit 1
fi

# Run prepare-network.sh
if LIBVIRT_URI="$LIBVIRT_URI" "$SCRIPT_DIR/prepare-network.sh"; then
    echo ""
    
    # Verify network is active
    echo "Verifying network..."
    sleep 2
    
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null | grep -q "Active.*yes"; then
        echo -e "${GREEN}Network '$NETWORK_NAME' is active${NC}"
        exit 0
    else
        echo -e "${RED}ERROR: Network '$NETWORK_NAME' is not active${NC}"
        exit 1
    fi
else
    echo -e "${RED}ERROR: Failed to setup network${NC}"
    exit 1
fi
