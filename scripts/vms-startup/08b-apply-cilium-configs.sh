#!/bin/bash
# =============================================================================
# Step 08b: Apply Cilium-Ready Configs (BEFORE Talos Install)
# =============================================================================
# This step applies Talos configs with Cilium-ready settings IMMEDIATELY
# after VMs boot from ISO, BEFORE Talos auto-installs to disk.
#
# CRITICAL: This must run within ~30 seconds of VM boot, before Talos
# installs to disk. The security settings are applied at install time.
#
# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Configuration
CONFIG_APPLY_WAIT=60   # 1 minute max to apply configs
CONFIG_APPLY_INTERVAL=2
CONFIG_APPLY_ELAPSED=0

# Path to config files
CONFIG_DIR="$PROJECT_ROOT/talos-cluster"

echo "[8b/13] Applying Cilium-Ready Configs (BEFORE Talos Install)..."
echo ""
echo "  CRITICAL: Applying configs before Talos installs to disk"
echo "  This enables Cilium eBPF support by disabling seccomp profile"
echo ""

# Verify config files exist
if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ERROR: Config files not found in $CONFIG_DIR"
    echo "  Run talos-bootstrap.sh first to generate configs"
    echo ""
    echo "  Continuing without Cilium support..."
    exit 0
fi

# Verify Cilium-ready settings in config
echo "  Verifying Cilium-ready settings..."
SECCOMP_DISABLED=$(grep -c "defaultRuntimeSeccompProfileEnabled: false" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null || echo "0")

if [[ "$SECCOMP_DISABLED" -eq 0 ]]; then
    echo "  WARNING: Seccomp profile not disabled in controlplane.yaml"
    echo "  Cilium may not work correctly"
    echo ""
    echo "  To enable Cilium support, ensure controlplane.yaml has:"
    echo "    machine:"
    echo "      kubelet:"
    echo "        defaultRuntimeSeccompProfileEnabled: false"
    echo ""
    echo "  Continuing anyway..."
else
    echo "  ✓ Cilium-ready settings verified"
fi
echo ""

# Get all IPs from libvirt network
echo "  Getting VM IPs from DHCP..."
mapfile -t VM_IPS < <(get_dhcp_ips "$NETWORK_NAME")

if [[ ${#VM_IPS[@]} -lt 1 ]]; then
    echo "  ERROR: No VM IPs found"
    echo "  Continuing without config apply..."
    exit 0
fi

MASTER_IP="${VM_IPS[0]:-10.0.0.10}"
echo "  Master IP: $MASTER_IP"
echo ""

# Wait for Talos API to be accessible in maintenance mode
echo "  Waiting for Talos maintenance mode API..."
while [[ $CONFIG_APPLY_ELAPSED -lt $CONFIG_APPLY_WAIT ]]; do
    # Check if Talos is accessible
    if talosctl version --nodes "$MASTER_IP" --insecure &>/dev/null; then
        echo "  ✓ Talos maintenance mode API accessible"
        break
    fi

    echo "  ⏳ Waiting for Talos API... (${CONFIG_APPLY_ELAPSED}s)"
    sleep $CONFIG_APPLY_INTERVAL
    CONFIG_APPLY_ELAPSED=$((CONFIG_APPLY_ELAPSED + CONFIG_APPLY_INTERVAL))
done

if [[ $CONFIG_APPLY_ELAPSED -ge $CONFIG_APPLY_WAIT ]]; then
    echo "  WARNING: Talos API not accessible after ${CONFIG_APPLY_WAIT}s"
    echo "  Talos may have already installed to disk"
    echo "  Continuing without config apply..."
    exit 0
fi

# Apply configs to master
echo ""
echo "  Applying controlplane config to master ($MASTER_IP)..."
if talosctl apply-config --nodes "$MASTER_IP" --file "$CONFIG_DIR/controlplane.yaml" --insecure 2>&1; then
    echo "  ✓ Controlplane config applied"
else
    echo "  ERROR: Failed to apply controlplane config"
    echo "  Talos may have already installed to disk"
    echo "  Continuing anyway..."
fi

# Apply configs to workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"

    echo ""
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    if talosctl apply-config --nodes "$WORKER_IP" --file "$CONFIG_DIR/worker.yaml" --insecure 2>&1; then
        echo "  ✓ Worker config applied to $WORKER_NAME"
    else
        echo "  ERROR: Failed to apply worker config to $WORKER_NAME"
        echo "  Continuing anyway..."
    fi
done

echo ""
echo "  ✓ Cilium-ready configs applied"
echo ""
echo "  Talos will now install with Cilium support enabled"
echo "  After install, VMs will reboot automatically"
echo ""
