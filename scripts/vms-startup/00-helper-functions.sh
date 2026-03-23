#!/bin/bash
# Step 00: Helper Functions
# Common functions used across all steps

# Get IPs from libvirt network
get_libvirt_ips() {
  local network="${1:-default}"
  local proto="${2:-all}"  # ipv4, ipv6, all

  local filter="NR > 2"
  case "$proto" in
    ipv4) filter="$filter && \$4 == \"ipv4\"" ;;
    ipv6) filter="$filter && \$4 == \"ipv6\"" ;;
    all)  filter="$filter" ;;
    *)    echo "Invalid protocol: $proto" >&2; return 1 ;;
  esac

  virsh -c "qemu:///system" net-dhcp-leases "$network" 2>/dev/null | \
    awk "$filter { gsub(\"/.*\", \"\", \$5); print \$5 }"
}

# Get IP for a specific VM by matching MAC address
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
