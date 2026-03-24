#!/bin/bash
# Step 10: Summary
# Displays startup summary and next steps

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[10/10] Startup Summary"
echo "======================"
echo "Cluster Name: ${CLUSTER_NAME:-talos-cluster}"
echo "Network: $NETWORK_NAME"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes (starting at $WORKER_IP_BASE)"
echo ""

if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    echo "Boot Mode: Raw Disk Image (CoW overlays)"
    echo "Boot Status:"
    echo "  ✓ Base image prepared: $TALOS_RAW_IMAGE_PATH"
    echo "  ✓ VM disk overlays created"
    echo "  ✓ VMs booted from pre-installed disk"
    echo ""
    echo "  Note: Raw image mode provides faster provisioning."
    echo "        Each VM uses a copy-on-write overlay."
else
    echo "Boot Mode: ISO Installation"
    echo "Boot Status:"
    echo "  ✓ VMs booted from ISO (initial install)"
    echo "  ✓ Talos installed to disk"
    echo "  ✓ VMs rebooted from disk"
    echo ""
fi

echo "Next steps:"
echo "  1. Bootstrap Talos cluster:"
echo "     ./scripts/talos-bootstrap.sh"
echo ""
echo "  2. After bootstrap, install Kubernetes components:"
echo "     ./scripts/k8s-components.sh"
echo ""
echo "  3. (Optional) Install Istio with Envoy Gateway:"
echo "     ./scripts/istio-install.sh"
echo ""
echo "=== VM Startup Complete ==="
