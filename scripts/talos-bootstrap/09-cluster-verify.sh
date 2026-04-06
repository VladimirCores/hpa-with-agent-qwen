#!/bin/bash
# =============================================================================
# Step 09: Cluster Verification
# =============================================================================
# Final verification of the Talos cluster and Kubernetes control plane.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[9/9] Final cluster verification..."
echo ""

# 1. Kubernetes nodes
echo "=== Kubernetes Nodes ==="
if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get nodes -o wide 2>&1; then
    echo ""
    NODE_COUNT=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get nodes --no-headers 2>/dev/null | wc -l)
    EXPECTED=$((1 + WORKER_COUNT))
    echo "  Nodes: $NODE_COUNT/$EXPECTED"
    if [[ $NODE_COUNT -eq $EXPECTED ]]; then
        echo "  ✓ All nodes present"
    else
        echo "  WARNING: Expected $EXPECTED nodes, found $NODE_COUNT"
    fi
else
    echo "  ✗ Could not get nodes"
    echo "  Cluster may still be initializing"
fi

echo ""

# 2. System pods
echo "=== System Pods (kube-system) ==="
if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system 2>&1; then
    echo ""
    PENDING=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    RUNNING=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    TOTAL=$((PENDING + RUNNING))
    echo "  Pods: $RUNNING Running, $PENDING Pending ($TOTAL total)"
    if [[ $PENDING -eq 0 ]]; then
        echo "  ✓ All system pods running"
    else
        echo "  ⏳ $PENDING pods still pending (may be normal during startup)"
    fi
else
    echo "  ✗ Could not get pods"
    echo "  Cluster may still be initializing"
fi

echo ""

# 3. Cluster info
echo "=== Cluster Info ==="
if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl cluster-info 2>&1 | grep -E "Kubernetes|CoreDNS"; then
    echo "  ✓ Cluster info verified"
else
    echo "  ✗ Could not get cluster info"
fi

echo ""

# 4. Talos version
echo "=== Talos Version ==="
for node in "$MASTER_IP" $(for i in $(seq 1 $WORKER_COUNT); do echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}'; done); do
    NODE_NAME=$(echo "$node" | awk -F. '{print "192.168.123."$4}')
    VERSION=$(talosctl version --nodes "$node" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 | grep "Tag:" | head -1 | awk '{print $2}' || echo "unknown")
    echo "  $NODE_NAME: $VERSION"
done

echo ""

# 5. Network info
echo "=== Network ==="
echo "  Network: $NETWORK_NAME"
echo "  Bridge: $BRIDGE_NAME"
echo "  CIDR: $NETWORK_CIDR"
echo "  Forward Mode: $FORWARD_MODE"
echo ""
echo "  DHCP Leases:"
virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | tail -n +3 | head -10 || echo "  (none)"

echo ""

# Summary
echo "=== Bootstrap Summary ==="
echo "Cluster: $CLUSTER_NAME"
echo "Endpoint: https://$MASTER_IP:6443"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes"
echo ""
echo "Configuration files: $CONFIG_DIR/"
echo "  - secrets.yaml"
echo "  - controlplane.yaml"
echo "  - worker.yaml"
echo "  - talosconfig"
echo "  - kubeconfig"
echo ""
echo "Next steps:"
echo "  1. Install Kubernetes components:"
echo "     ./scripts/k8s-components.sh"
echo "  2. Install Cilium CNI:"
echo "     ./scripts/k8s-components.sh --cni-cilium"
echo "  3. Install metrics-server for HPA:"
echo "     ./scripts/k8s-components.sh -m"
echo ""
echo "  ✓ Cluster verification completed"
echo ""
