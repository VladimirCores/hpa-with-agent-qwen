#!/bin/bash
# =============================================================================
# Step 02: Check Prerequisites
# =============================================================================
# Verifies all required tools and services are available.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/11] Checking prerequisites..."
echo "  Vagrantfile: $PROJECT_ROOT/Vagrantfile"
echo "  Libvirt URI: $LIBVIRT_URI"
echo ""

# Check Vagrantfile
echo -n "  Checking Vagrantfile... "
if [[ ! -f "$PROJECT_ROOT/Vagrantfile" ]]; then
    echo "ERROR: Vagrantfile not found"
    exit 1
fi
echo "OK"

# Check vagrant-libvirt plugin
echo -n "  Checking vagrant-libvirt plugin... "
if vagrant plugin list 2>/dev/null | grep -q vagrant-libvirt; then
    echo "OK ($(vagrant plugin list 2>/dev/null | grep vagrant-libvirt | awk '{print $1}'))"
else
    echo "ERROR: vagrant-libvirt plugin not installed"
    echo "  Install with: vagrant plugin install vagrant-libvirt"
    exit 1
fi

# Check libvirtd
echo -n "  Checking libvirtd service... "
if systemctl is-active --quiet libvirtd 2>/dev/null; then
    echo "OK (running)"
else
    echo "ERROR: libvirtd is not running"
    echo "  Start with: sudo systemctl start libvirtd"
    exit 1
fi

# Check user permissions
echo -n "  Checking user permissions... "
if [[ "$LIBVIRT_URI" == "qemu:///system" ]]; then
    if virsh -c "$LIBVIRT_URI" uri >/dev/null 2>&1; then
        echo "OK (system mode)"
    else
        echo "ERROR: Cannot connect to libvirt at $LIBVIRT_URI"
        echo "  Ensure user is in libvirt group or has polkit rules"
        exit 1
    fi
else
    if virsh -c "$LIBVIRT_URI" uri >/dev/null 2>&1; then
        echo "OK (session mode)"
    else
        echo "ERROR: Cannot connect to libvirt at $LIBVIRT_URI"
        exit 1
    fi
fi

# Check required tools
echo ""
echo "  Checking required tools..."
for cmd in virsh talosctl kubectl qemu-img; do
    echo -n "    $cmd: "
    if command -v "$cmd" &>/dev/null; then
        version=$("$cmd" --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "installed")
        echo "✓ ($version)"
    else
        echo "✗ not found"
        echo "    Install with: sudo dnf install $cmd  OR  sudo apt install $cmd"
    fi
done

echo ""
echo "All prerequisites met"
echo ""
