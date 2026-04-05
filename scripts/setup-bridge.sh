#!/bin/bash
# =============================================================================
# Setup Bridge for User Session Mode VMs
# =============================================================================
# This script creates a Linux bridge for use with libvirt session mode.
# Run once with sudo to create the bridge, then VMs can run in user session.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "ERROR: .env file not found"
    exit 1
fi

# Source sudo helper
SUDO_HELPER="$PROJECT_ROOT/scripts/vms-startup/00-sudo-helper.sh"
if [[ -f "$SUDO_HELPER" ]]; then
    source "$SUDO_HELPER"
else
    run_sudo() {
        if [[ -n "${SUDO_PASSWORD:-}" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
        else
            sudo "$@"
        fi
    }
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# =============================================================================
# Main Script
# =============================================================================

print_header "Setup Bridge for User Session Mode"

echo "Configuration:"
echo "  BRIDGE_NAME:  $BRIDGE_NAME"
echo "  NETWORK_IP:   $NETWORK_IP"
echo "  NETWORK_MASK: $NETWORK_MASK"
echo "  DHCP_START:   $DHCP_START"
echo "  DHCP_END:     $DHCP_END"
echo ""

# =============================================================================
# Step 1: Create Bridge Interface
# =============================================================================
print_step "Step 1/4: Creating bridge interface..."

if ip link show "$BRIDGE_NAME" &>/dev/null; then
    echo "  Bridge '$BRIDGE_NAME' already exists"
else
    echo "  Creating bridge interface '$BRIDGE_NAME'..."
    if run_sudo ip link add name "$BRIDGE_NAME" type bridge; then
        print_success "Bridge interface created"
    else
        print_error "Failed to create bridge interface"
        exit 1
    fi
fi

# =============================================================================
# Step 2: Configure Bridge IP
# =============================================================================
print_step "Step 2/4: Configuring bridge IP address..."

# Check if IP is already assigned
if ip addr show "$BRIDGE_NAME" | grep -q "$NETWORK_IP"; then
    echo "  Bridge already has IP $NETWORK_IP"
else
    echo "  Assigning IP $NETWORK_IP/$NETWORK_MASK to bridge..."
    sudo ip addr add "$NETWORK_IP/$NETWORK_MASK" dev "$BRIDGE_NAME"
    print_success "Bridge IP configured"
fi

# Bring up the bridge
if ip link show "$BRIDGE_NAME" | grep -q "state UP"; then
    echo "  Bridge is already UP"
else
    echo "  Bringing up bridge interface..."
    run_sudo ip link set "$BRIDGE_NAME" up
    print_success "Bridge is UP"
fi

# =============================================================================
# Step 3: Add Bridge to QEMU ACL
# =============================================================================
print_step "Step 3/4: Adding bridge to QEMU ACL..."

if grep -q "$BRIDGE_NAME" /etc/qemu/bridge.conf 2>/dev/null; then
    echo "  Bridge already in QEMU ACL"
else
    echo "  Adding '$BRIDGE_NAME' to /etc/qemu/bridge.conf..."
    echo "allow $BRIDGE_NAME" | run_sudo tee -a /etc/qemu/bridge.conf > /dev/null
    print_success "Bridge added to QEMU ACL"
fi

# =============================================================================
# Step 4: Setup dnsmasq for DHCP
# =============================================================================
print_step "Step 4/4: Setting up dnsmasq for DHCP..."

# Check if dnsmasq is installed
if ! command -v dnsmasq &>/dev/null; then
    print_error "dnsmasq is not installed"
    echo "  Please install dnsmasq: sudo dnf install dnsmasq"
    exit 1
fi

# Generate static host entries for DHCP reservations
generate_static_hosts() {
    local hosts=""
    
    # Helper function to increment IP
    increment_ip() {
        local ip="$1"
        local increment="${2:-0}"
        local base_ip="${ip%.*}"
        local last_octet="${ip##*.}"
        echo "${base_ip}.$((last_octet + increment))"
    }
    
    # Master node
    hosts+="dhcp-host=${MAC_PREFIX}:01,$MASTER_NAME,$MASTER_IP\n"
    
    # Worker nodes
    for i in $(seq 1 "$WORKER_COUNT"); do
        worker_ip=$(increment_ip "$WORKER_IP_BASE" $((i - 1)))
        worker_mac=$(printf "${MAC_PREFIX}:%02x" $((10 + i)))
        worker_name="${WORKER_NAME_PREFIX}${i}"
        hosts+="dhcp-host=$worker_mac,$worker_name,$worker_ip\n"
    done
    
    echo -e "$hosts"
}

# Create dnsmasq configuration
DNSMASQ_CONF_DIR="$PROJECT_ROOT/.dnsmasq"
DNSMASQ_CONF="$DNSMASQ_CONF_DIR/cluster.conf"
DNSMASQ_PIDFILE="$DNSMASQ_CONF_DIR/dnsmasq.pid"

mkdir -p "$DNSMASQ_CONF_DIR"

STATIC_HOSTS=$(generate_static_hosts)

cat > "$DNSMASQ_CONF" <<EOF
# dnsmasq configuration for Talos cluster bridge
# DHCP only mode - DNS handled by upstream
interface=$BRIDGE_NAME
except-interface=lo
bind-dynamic
port=0
dhcp-range=$DHCP_START,$DHCP_END,$NETWORK_MASK,12h
pid-file=$DNSMASQ_PIDFILE

# Static IP reservations
$(echo -e "$STATIC_HOSTS")

# Logging (optional)
log-dhcp
EOF

print_success "dnsmasq configuration created: $DNSMASQ_CONF"

# Kill any existing dnsmasq for this bridge
if pgrep -f "dnsmasq.*--conf-file.*$DNSMASQ_CONF" > /dev/null; then
    echo "  Stopping existing dnsmasq for $BRIDGE_NAME..."
    run_sudo pkill -f "dnsmasq.*--conf-file.*$DNSMASQ_CONF" || true
    sleep 1
fi

# Also kill by PID file if exists
if [[ -f "$DNSMASQ_PIDFILE" ]]; then
    OLD_PID=$(cat "$DNSMASQ_PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "  Stopping dnsmasq (PID: $OLD_PID)..."
        run_sudo kill "$OLD_PID" 2>/dev/null || run_sudo kill -9 "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$DNSMASQ_PIDFILE"
fi

# Start dnsmasq as root (required for DHCP server on port 67)
echo "  Starting dnsmasq..."
if run_sudo dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PIDFILE" 2>/dev/null; then
    sleep 2
    if [[ -f "$DNSMASQ_PIDFILE" ]] && kill -0 "$(cat "$DNSMASQ_PIDFILE")" 2>/dev/null; then
        print_success "dnsmasq started (PID: $(cat "$DNSMASQ_PIDFILE"))"
    else
        print_error "Failed to start dnsmasq"
        exit 1
    fi
else
    # dnsmasq may already be running, check if it's working
    echo "  WARNING: dnsmasq start command failed, checking if already running..."
    sleep 1
    if pgrep -f "dnsmasq.*$BRIDGE_NAME" > /dev/null || pgrep -f "dnsmasq.*--conf-file.*$DNSMASQ_CONF" > /dev/null; then
        echo "  ✓ dnsmasq is already running"
    else
        print_error "Failed to start dnsmasq"
        exit 1
    fi
fi

# =============================================================================
# Summary
# =============================================================================
print_header "Bridge Setup Complete"

echo -e "${GREEN}Bridge '$BRIDGE_NAME' is ready for user session mode VMs!${NC}"
echo ""
echo "Bridge configuration:"
echo "  Name:       $BRIDGE_NAME"
echo "  IP:         $NETWORK_IP/$NETWORK_MASK"
echo "  DHCP Range: $DHCP_START - $DHCP_END"
echo ""
echo "Static IP reservations:"
echo "  - $MASTER_NAME: $MASTER_IP"
for i in $(seq 1 "$WORKER_COUNT"); do
    worker_ip=$(echo "$WORKER_IP_BASE" | awk -F. '{print $1"."$2"."$3"."($4+i-1)}')
    echo "  - ${WORKER_NAME_PREFIX}${i}: $worker_ip"
done
echo ""
echo "Next steps:"
echo "  1. Run ./startup.sh to start VMs (no sudo needed)"
echo "  2. VMs will connect to bridge '$BRIDGE_NAME'"
echo "  3. dnsmasq will assign static IPs via DHCP"
echo ""
echo "To stop dnsmasq later:"
echo "  pkill -f 'dnsmasq.*$BRIDGE_NAME'"
echo ""

exit 0
