#!/bin/bash
# =============================================================================
# Set VM Boot Order to Disk (after Talos install)
# =============================================================================
# This script changes VM boot order from CDROM to disk after Talos is installed.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

echo "=== Setting VM Boot Order to Disk ==="
echo ""

# Get VM names (handle Vagrant prefix)
MASTER_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${MASTER_NAME}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
WORKER_VMS=()
for i in $(seq 1 $WORKER_COUNT); do
    VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${WORKER_NAME_PREFIX}${i}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$VM" ]]; then
        WORKER_VMS+=("$VM")
    fi
done

# Function to change boot order for a VM
set_disk_boot() {
    local vm_name="$1"
    echo "  Setting disk boot for: $vm_name"

    # Get current XML
    local xml=$(virsh -c "$LIBVIRT_URI" dumpxml "$vm_name")

    # Remove CDROM boot entries
    xml=$(echo "$xml" | sed "/<boot dev='cdrom'>/d")

    # Ensure disk boot is first (add if not present)
    if ! echo "$xml" | grep -q "<boot dev='hd'/>"; then
        xml=$(echo "$xml" | sed "/<os>/a\    <boot dev='hd'/>")
    fi

    # Update VM definition
    echo "$xml" | virsh -c "$LIBVIRT_URI" define /dev/stdin

    echo "    ✓ Boot order changed to disk"
}

# Set boot order for master
if [[ -n "$MASTER_VM" ]]; then
    set_disk_boot "$MASTER_VM"
else
    echo "  WARNING: Master VM not found"
fi

# Set boot order for workers
for vm in "${WORKER_VMS[@]}"; do
    set_disk_boot "$vm"
done

echo ""
echo "=== Boot Order Changed ==="
echo ""
echo "VMs will now boot from disk on next reboot."
echo "The Talos ISO can be safely detached if desired."
echo ""
