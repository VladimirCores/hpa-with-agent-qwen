#!/bin/bash
# =============================================================================
# Prepare Talos Cluster Network
# =============================================================================
# This script sets up an isolated libvirt network for the Talos cluster.
# It checks if the network already exists and deletes it before creating a new one.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

echo "=== Preparing Talos Cluster Network ==="
echo "Network Name: $NETWORK_NAME"
echo "Bridge Name: $BRIDGE_NAME"
echo "Network CIDR: $NETWORK_CIDR"
echo "DHCP Range: $DHCP_START - $DHCP_END"
echo "Forward Mode: $FORWARD_MODE"
echo ""
# Helper function to increment IP address (only last octet)
increment_ip() {
    local ip="$1"
    local increment="${2:-0}"
    local base_ip="${ip%.*}"
    local last_octet="${ip##*.}"
    echo "${base_ip}.$((last_octet + increment))"
}

echo "Static IP Reservations:"
echo "  - $MASTER_NAME: $MASTER_IP"
for i in $(seq 1 $WORKER_COUNT); do
    worker_ip=$(increment_ip "$WORKER_IP_BASE" $((i - 1)))
    worker_name="${WORKER_NAME_PREFIX}${i}"
    echo "  - $worker_name: $worker_ip"
done
echo ""

# Check if network exists and delete it
echo "Checking if network '$NETWORK_NAME' already exists..."
if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
    echo "Network '$NETWORK_NAME' found. Deleting..."

    # Step 1: Destroy the network if it's active
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null | grep -E "^Active:" | grep -q "yes"; then
        echo "  - Destroying active network..."
        virsh -c "$LIBVIRT_URI" net-destroy "$NETWORK_NAME"

        # Wait for network to become inactive (async operation)
        echo "  - Waiting for network to become inactive..."
        while virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null | grep -E "^Active:" | grep -q "yes"; do
            sleep 0.5
        done
        echo "  - Network is now inactive"
    else
        echo "  - Network is already inactive"
    fi

    # Step 2: Undefine the network if it's persistent
    if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null | grep -E "^Persistent:" | grep -q "yes"; then
        echo "  - Undefining persistent network..."
        virsh -c "$LIBVIRT_URI" net-undefine "$NETWORK_NAME"
    else
        echo "  - Network is transient (will be auto-removed)"
    fi

    # Step 3: Wait for network to be fully removed (async operation)
    echo "  - Waiting for network to be fully removed..."
    while virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; do
        sleep 0.5
    done
    echo "  - Network removed"

    # Step 4: Delete the bridge interface if it still exists (cleanup)
    if ip link show "$BRIDGE_NAME" &>/dev/null; then
        echo "  - Removing bridge interface '$BRIDGE_NAME'..."
        ip link delete "$BRIDGE_NAME" 2>/dev/null || true
        # Wait for bridge to be fully removed
        echo "  - Waiting for bridge interface to be removed..."
        while ip link show "$BRIDGE_NAME" &>/dev/null; do
            sleep 0.5
        done
        echo "  - Bridge removed"
    else
        echo "  - Bridge interface '$BRIDGE_NAME' does not exist (already cleaned up)"
    fi

    echo "Network '$NETWORK_NAME' deleted successfully."
else
    echo "Network '$NETWORK_NAME' does not exist. Proceeding with creation..."
fi

echo ""

# Generate static host entries for DHCP reservations
generate_static_hosts() {
    local hosts=""

    # Master node static IP (MAC: 52:54:00:00:00:01)
    hosts+="    <host mac='${MAC_PREFIX}:01' name='${MASTER_NAME}' ip='${MASTER_IP}'/>\n"

    # Worker nodes static IPs (MACs: 52:54:00:00:00:11, 52:54:00:00:00:12, etc.)
    for i in $(seq 1 $WORKER_COUNT); do
        worker_ip=$(increment_ip "$WORKER_IP_BASE" $((i - 1)))
        worker_mac=$(printf "${MAC_PREFIX}:%02x" $((10 + i)))
        worker_name="${WORKER_NAME_PREFIX}${i}"
        hosts+="    <host mac='${worker_mac}' name='${worker_name}' ip='${worker_ip}'/>\n"
    done

    echo -e "$hosts"
}

# Create network XML definition
echo "Creating network definition..."
STATIC_HOSTS=$(generate_static_hosts)

NETWORK_XML=$(cat <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='$FORWARD_MODE'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='$BRIDGE_NAME' stp='on' delay='0'/>
  <ip address='$NETWORK_IP' netmask='$NETWORK_MASK'>
    <dhcp>
      <range start='$DHCP_START' end='$DHCP_END'/>
$(echo -e "$STATIC_HOSTS")
    </dhcp>
  </ip>
</network>
EOF
)

# Define and start the network
echo "Defining network '$NETWORK_NAME'..."
echo "$NETWORK_XML" | virsh -c "$LIBVIRT_URI" net-define /dev/stdin

echo "Starting network '$NETWORK_NAME'..."
virsh -c "$LIBVIRT_URI" net-start "$NETWORK_NAME"

# Set network to autostart on boot
echo "Setting network to autostart..."
virsh -c "$LIBVIRT_URI" net-autostart "$NETWORK_NAME"

echo ""
echo "=== Network Setup Complete ==="
echo ""
echo "Network details:"
virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME"
