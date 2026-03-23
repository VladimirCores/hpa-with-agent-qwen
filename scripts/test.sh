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

check_machine_ready() {
    local ip="$1"
    # Get machine status in YAML format and extract READY value
    local ready
    ready=$(talosctl -n "$ip" get machinestatus --insecure -o json 2>/dev/null | yq -r '.spec.status.ready // "null"')
    if [[ "$ready" == "true" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

get_libvirt_ips 'cluster-talos-net' all

check_machine_ready "10.0.0.10"
