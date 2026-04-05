#!/bin/bash
# =============================================================================
# Step 05: Setup Network
# =============================================================================
# For bridge mode: runs setup-bridge.sh (creates bridge + dnsmasq)
# For NAT mode: runs prepare-network.sh (creates libvirt network)
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

# For bridge mode, run setup-bridge.sh
if [[ "$FORWARD_MODE" == "bridge" ]]; then
    echo "Bridge mode detected - setting up bridge interface..."
    echo ""
    
    # Check setup-bridge.sh exists
    if [[ ! -x "$SCRIPT_DIR/setup-bridge.sh" ]]; then
        echo -e "${RED}ERROR: setup-bridge.sh not found or not executable${NC}"
        exit 1
    fi
    
    # Run setup-bridge.sh (will prompt for sudo if needed)
    if "$SCRIPT_DIR/setup-bridge.sh"; then
        echo ""
        echo -e "${GREEN}✓ Bridge setup completed${NC}"
        exit 0
    else
        echo -e "${RED}ERROR: Failed to setup bridge${NC}"
        exit 1
    fi
fi

# For NAT mode, run prepare-network.sh
if [[ ! -x "$SCRIPT_DIR/prepare-network.sh" ]]; then
    echo -e "${RED}ERROR: prepare-network.sh not found or not executable${NC}"
    exit 1
fi

# Run prepare-network.sh
if LIBVIRT_URI="$LIBVIRT_URI" "$SCRIPT_DIR/prepare-network.sh"; then
    echo ""
    echo -e "${GREEN}✓ Network setup completed${NC}"
    exit 0
else
    echo -e "${RED}ERROR: Failed to setup network${NC}"
    exit 1
fi
