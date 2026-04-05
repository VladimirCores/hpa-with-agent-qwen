#!/bin/bash
# =============================================================================
# Prepare Talos Cluster Network
# =============================================================================
# For bridge mode: verifies bridge exists (dnsmasq handles DHCP)
# For NAT mode: creates libvirt network with NAT
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Source sudo helper
SUDO_HELPER="$PROJECT_ROOT/scripts/vms-startup/00-sudo-helper.sh"
if [[ -f "$SUDO_HELPER" ]]; then
    source "$SUDO_HELPER"
else
    # Fallback: define run_sudo if helper not found
    run_sudo() {
        if [[ -n "${SUDO_PASSWORD:-}" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
        else
            sudo "$@"
        fi
    }
fi

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

# For bridge mode, skip libvirt network (dnsmasq handles DHCP)
if [[ "$FORWARD_MODE" == "bridge" ]]; then
    echo "Bridge mode: skipping libvirt network setup"
    echo "  Bridge interface: $BRIDGE_NAME"
    echo "  DHCP server: dnsmasq (user session)"
    echo ""
    
    # Verify bridge exists
    if ip link show "$BRIDGE_NAME" &>/dev/null; then
        echo "✓ Bridge '$BRIDGE_NAME' exists and is ready"
    else
        echo "✗ Bridge '$BRIDGE_NAME' does not exist"
        echo "  Run: ./scripts/setup-bridge.sh"
        exit 1
    fi
    
    # Verify dnsmasq is running
    DNSMASQ_CONF_DIR="$PROJECT_ROOT/.dnsmasq"
    DNSMASQ_CONF="$DNSMASQ_CONF_DIR/cluster.conf"
    if [[ -f "$DNSMASQ_CONF" ]] && pgrep -f "dnsmasq.*--conf-file.*$DNSMASQ_CONF" > /dev/null; then
        echo "✓ dnsmasq is running for '$BRIDGE_NAME'"
    else
        echo "⚠ dnsmasq is not running for '$BRIDGE_NAME'"
        echo "  Run: ./scripts/setup-bridge.sh"
    fi
    
    echo ""
    echo "=== Network Setup Complete ==="
    exit 0
fi

# Check if network exists and delete it (for NAT mode only)
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

    echo "Network '$NETWORK_NAME' deleted successfully."
else
    echo "Network '$NETWORK_NAME' does not exist. Proceeding with creation..."
fi

echo ""

# Create bridge interface if it doesn't exist (required for NAT mode)
# This must be done before libvirt can start the network
create_bridge_interface() {
    if [[ "$FORWARD_MODE" == "nat" ]]; then
        echo "Creating bridge interface for NAT mode..."
        
        # Check if bridge already exists
        if ip link show "$BRIDGE_NAME" &>/dev/null; then
            echo "  ✓ Bridge interface '$BRIDGE_NAME' already exists"
            return 0
        fi
        
        # Create bridge interface (requires sudo)
        echo "  Creating bridge interface '$BRIDGE_NAME'..."
        if run_sudo ip link add name "$BRIDGE_NAME" type bridge; then
            echo "  ✓ Bridge interface created"
            
            # Bring up the bridge
            echo "  Bringing up bridge interface..."
            run_sudo ip link set "$BRIDGE_NAME" up
            echo "  ✓ Bridge interface is up"
            
            # Add to polkit ACL if not already present
            if ! grep -q "$BRIDGE_NAME" /etc/qemu/bridge.conf 2>/dev/null; then
                echo "  Adding bridge to QEMU ACL..."
                echo "allow $BRIDGE_NAME" | run_sudo tee -a /etc/qemu/bridge.conf > /dev/null
                echo "  ✓ Bridge added to ACL"
            fi
            
            return 0
        else
            echo "  ✗ Failed to create bridge interface"
            return 1
        fi
    fi
    return 0
}

# Wait for network to become active with polling
wait_for_network_active() {
    local max_attempts=30
    local attempt=1
    local delay=1
    
    echo "  Waiting for network to become active..."
    
    while [[ $attempt -le $max_attempts ]]; do
        sleep $delay
        
        if virsh -c "$LIBVIRT_URI" net-list --all 2>/dev/null | grep -E "^\s+$NETWORK_NAME\s+active" > /dev/null; then
            echo "  ✓ Network is active (attempt $attempt/$max_attempts)"
            return 0
        fi
        
        echo "  ... polling (attempt $attempt/$max_attempts)"
        ((attempt++))
    done
    
    echo "  ✗ Network failed to become active after $max_attempts attempts"
    return 1
}

# Create bridge interface before network setup
create_bridge_interface

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

# For bridge mode, use existing bridge interface (no DHCP, no IP - bridge handles it)
# For NAT mode in session mode, don't specify bridge (libvirt creates virbrX)
# For NAT mode in system mode, use configured bridge name
if [[ "$FORWARD_MODE" == "bridge" ]]; then
    # Bridge mode: use existing bridge interface (no IP/DHCP - bridge handles networking)
    NETWORK_XML=$(cat <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='bridge'/>
  <bridge name='$BRIDGE_NAME'/>
</network>
EOF
)
    echo "  Using bridge mode with existing interface: $BRIDGE_NAME"
    echo "  Note: DHCP reservations handled by bridge, not libvirt network"
elif [[ "$LIBVIRT_URI" == "qemu:///session" ]]; then
    # Session mode with NAT: use pre-created bridge (session mode cannot create bridges)
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
    echo "  Using NAT mode with pre-created bridge: $BRIDGE_NAME"
else
    # System mode with NAT: let libvirt create its own bridge
    NETWORK_XML=$(cat <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='$FORWARD_MODE'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='$NETWORK_IP' netmask='$NETWORK_MASK'>
    <dhcp>
      <range start='$DHCP_START' end='$DHCP_END'/>
$(echo -e "$STATIC_HOSTS")
    </dhcp>
  </ip>
</network>
EOF
)
    echo "  Using NAT mode (libvirt will create bridge)"
fi

# Define and start the network
echo "Defining network '$NETWORK_NAME'..."
echo "$NETWORK_XML" | virsh -c "$LIBVIRT_URI" net-define /dev/stdin || true

echo "Starting network '$NETWORK_NAME'..."
virsh -c "$LIBVIRT_URI" net-start "$NETWORK_NAME" || true

# Set network to autostart on boot
echo "Setting network to autostart..."
virsh -c "$LIBVIRT_URI" net-autostart "$NETWORK_NAME"

# Wait for network to become active (polling)
wait_for_network_active

echo ""
echo "=== Network Setup Complete ==="
echo ""
echo "Network details:"
virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME"
