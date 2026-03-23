#!/bin/bash
# Step 00: Helper Functions
# Common functions used across all steps

# Source common setup first
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Get DHCP lease IPs from a libvirt network
# Usage: get_dhcp_ips [network_name]
# Returns: Space-separated list of IPv4 addresses
get_dhcp_ips() {
    local network="${1:-${NETWORK_NAME:-cluster-talos-net}}"
    local virsh_uri="${LIBVIRT_URI:-qemu:///system}"

    # Get DHCP leases and extract IPv4 addresses
    # Run virsh directly (works when script is run with sudo)
    virsh -c "$virsh_uri" net-dhcp-leases "$network" 2>/dev/null | \
        awk 'NR > 2 && $4 == "ipv4" { gsub("/.*", "", $5); print $5 }'
}

# Alias for backward compatibility
libvirt_get_dhcp_ips() {
    get_dhcp_ips "$@"
}

# Get IP for a specific VM by matching MAC address
# Usage: get_vm_ip <vm_name> [network]
get_vm_ip() {
  local vm_name="$1"
  local network="${2:-$NETWORK_NAME}"

  # Get VM's MAC address
  local vm_mac
  vm_mac=$(virsh -c "$LIBVIRT_URI" domifaddr "$vm_name" 2>/dev/null | grep -v "^-" | awk '{print $2}' | head -1)

  if [[ -z "$vm_mac" ]]; then
    echo ""
    return
  fi

  # Find IP by matching MAC in DHCP leases
  local ip
  ip=$(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$network" 2>/dev/null | grep "$vm_mac" | awk '{gsub("/.*", "", $5); print $5}')
  echo "$ip"
}

# Check if Talos machine is ready
# Usage: check_machine_ready <ip_address>
# Returns: "true" or "false"
check_machine_ready() {
    local ip="$1"
    # Get machine status in YAML format and extract READY value
    local ready
    ready=$(timeout 3 talosctl -n "$ip" get machinestatus --insecure -o yaml 2>/dev/null | grep -i "ready:" | awk '{print $2}' | head -1 || echo "")
    if [[ "$ready" == "true" ]]; then
        echo "true"
    else
        echo "false"
    fi
}
