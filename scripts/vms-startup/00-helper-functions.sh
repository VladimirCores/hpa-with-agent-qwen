#!/bin/bash
# Step 00: Helper Functions
# Common functions used across all steps

# Source common setup first
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Get DHCP lease IPs from a libvirt network
# Usage: libvirt_get_dhcp_ips [--network NAME] [--protocol ipv4|ipv6|all] [--raw]
#
# Options:
#   --network, -n    Network name (default: from $NETWORK_NAME or "default")
#   --protocol, -p   Protocol filter: ipv4, ipv6, all (default: ipv4)
#   --raw, -r        Output raw IPs only (no error messages)
#   --help, -h       Show this help message
#
# Examples:
#   libvirt_get_dhcp_ips
#   libvirt_get_dhcp_ips --network cluster-talos-net --protocol ipv4
#   mapfile -t IPS < <(libvirt_get_dhcp_ips -n my-network -p ipv4)
libvirt_get_dhcp_ips() {
    local network=""
    local protocol="ipv4"
    local raw=false
    local virsh_uri="qemu:///system"

    # Parse named arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--network)
                network="$2"
                shift 2
                ;;
            -p|--protocol)
                protocol="$2"
                shift 2
                ;;
            -r|--raw)
                raw=true
                shift
                ;;
            -h|--help)
                echo "Usage: libvirt_get_dhcp_ips [--network NAME] [--protocol ipv4|ipv6|all] [--raw]"
                echo ""
                echo "Get DHCP lease IPs from a libvirt network"
                echo ""
                echo "Options:"
                echo "  --network, -n    Network name (default: \$NETWORK_NAME or 'default')"
                echo "  --protocol, -p   Protocol: ipv4, ipv6, all (default: ipv4)"
                echo "  --raw, -r        Output raw IPs only (no error messages)"
                echo "  --help, -h       Show this help message"
                return 0
                ;;
            *)
                if [[ "$raw" == "false" ]]; then
                    echo "Unknown option: $1" >&2
                    echo "Use --help for usage information" >&2
                fi
                return 1
                ;;
        esac
    done

    # Use default network if not specified
    network="${network:-${NETWORK_NAME:-default}}"

    # Build awk filter based on protocol
    local awk_filter='NR > 2'
    case "$protocol" in
        ipv4) awk_filter="$awk_filter && \$4 == \"ipv4\"" ;;
        ipv6) awk_filter="$awk_filter && \$4 == \"ipv6\"" ;;
        all)   awk_filter="$awk_filter" ;;
        *)
            if [[ "$raw" == "false" ]]; then
                echo "Error: Invalid protocol '$protocol'. Use: ipv4, ipv6, or all" >&2
            fi
            return 1
            ;;
    esac

    # Get DHCP leases and extract IPs
    local result
    result=$(virsh -c "$virsh_uri" net-dhcp-leases "$network" 2>/dev/null | \
        awk "$awk_filter { gsub(\"/.*\", \"\", \$5); if (\$5 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print \$5 }")

    if [[ -z "$result" && "$raw" == "false" ]]; then
        echo "Warning: No DHCP leases found for network '$network' (protocol: $protocol)" >&2
    fi

    echo "$result"
}

# Alias for backward compatibility
get_libvirt_ips() {
    libvirt_get_dhcp_ips -n "$1" -p "${2:-all}" -r
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
