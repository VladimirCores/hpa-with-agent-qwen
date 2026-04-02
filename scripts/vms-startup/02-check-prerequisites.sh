#!/bin/bash
# =============================================================================
# Step 02: Check Prerequisites
# =============================================================================
# Verifies Vagrantfile, vagrant-libvirt plugin, and libvirtd
# Returns: 0 on success, 1 on failure
# =============================================================================

set -euo pipefail

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Checking prerequisites..."
echo ""

# Check Vagrantfile exists
echo -n "  Checking Vagrantfile... "
if [[ ! -f "$PROJECT_ROOT/Vagrantfile" ]]; then
    echo -e "${RED}FAILED${NC}"
    echo "ERROR: Vagrantfile not found in $PROJECT_ROOT"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Check vagrant-libvirt plugin
echo -n "  Checking vagrant-libvirt plugin... "
if ! vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
    echo -e "${RED}FAILED${NC}"
    echo "ERROR: vagrant-libvirt plugin not installed"
    echo "  Install with: vagrant plugin install vagrant-libvirt"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Check libvirt is running
echo -n "  Checking libvirtd service... "
if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    echo "starting..."
    
    # Wait for libvirt to be ready (async startup)
    MAX_WAIT=30
    WAITED=0
    while ! virsh -c "$LIBVIRT_URI" list --all &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo -e "${RED}FAILED${NC}"
            echo "ERROR: libvirtd not responding after ${MAX_WAIT}s"
            exit 1
        fi
        sleep 1
        WAITED=$((WAITED + 1))
    done
    echo -e "${GREEN}OK${NC} (started in ${WAITED}s)"
else
    echo -e "${GREEN}OK${NC}"
fi

# Check user is in libvirt group (for session mode)
echo -n "  Checking user permissions... "
if [[ "$LIBVIRT_URI" == "qemu:///session" ]]; then
    if id -nG | grep -qw "libvirt"; then
        echo -e "${GREEN}OK${NC} (user in libvirt group)"
    else
        echo -e "${GREEN}OK${NC} (session mode)"
    fi
else
    echo -e "${GREEN}OK${NC} (system mode)"
fi

echo ""
echo -e "${GREEN}All prerequisites met${NC}"
exit 0
