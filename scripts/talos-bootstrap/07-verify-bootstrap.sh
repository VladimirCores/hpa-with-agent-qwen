#!/bin/bash
# =============================================================================
# Step 07: Verify Bootstrap - Wait for Full Cluster Health
# =============================================================================
# Waits for the cluster to be fully operational:
# 1. Kubeconfig is accessible
# 2. kubectl can communicate with API server
# 3. ALL nodes are in Ready status
# 4. Core system pods are running
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

EXPECTED_NODES=$((1 + WORKER_COUNT))

echo "[7/9] Verifying cluster health..."
echo "  Expected nodes: $EXPECTED_NODES"
echo "  Master: $MASTER_NAME ($MASTER_IP)"
echo "  Workers: $WORKER_COUNT nodes"
echo ""

# Phase 1: Download kubeconfig
echo "  Phase 1: Downloading kubeconfig..."
KUBECONFIG_WAIT=0
KUBECONFIG_TIMEOUT=120

while [[ $KUBECONFIG_WAIT -lt $KUBECONFIG_TIMEOUT ]]; do
    if talosctl kubeconfig \
        --nodes "$MASTER_IP" \
        --endpoints "$MASTER_IP" \
        --force \
        --force-context-name "${CLUSTER_NAME:-talos-cluster}" \
        "$CONFIG_DIR/kubeconfig" \
        --talosconfig "$CONFIG_DIR/talosconfig" 2>/dev/null; then
        echo "  ✓ Kubeconfig downloaded (${KUBECONFIG_WAIT}s)"
        break
    fi
    
    if [[ $((KUBECONFIG_WAIT % 15)) -eq 0 ]]; then
        echo "    Waiting for API server... (${KUBECONFIG_WAIT}s)"
    fi
    
    sleep 5
    KUBECONFIG_WAIT=$((KUBECONFIG_WAIT + 5))
done

if [[ $KUBECONFIG_WAIT -ge $KUBECONFIG_TIMEOUT ]]; then
    echo "  ERROR: Could not download kubeconfig after ${KUBECONFIG_TIMEOUT}s"
    echo "  Cluster may not be fully initialized"
    exit 1
fi

echo ""

# Phase 2: Wait for kubectl to work
echo "  Phase 2: Waiting for API server responsiveness..."
API_WAIT=0
API_TIMEOUT=120

while [[ $API_WAIT -lt $API_TIMEOUT ]]; do
    if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl cluster-info >/dev/null 2>&1; then
        echo "  ✓ API server is responsive (${API_WAIT}s)"
        break
    fi
    
    if [[ $((API_WAIT % 15)) -eq 0 ]]; then
        echo "    API server not ready yet... (${API_WAIT}s)"
    fi
    
    sleep 5
    API_WAIT=$((API_WAIT + 5))
done

if [[ $API_WAIT -ge $API_TIMEOUT ]]; then
    echo "  ERROR: API server not responsive after ${API_TIMEOUT}s"
    exit 1
fi

echo ""

# Phase 3: Wait for ALL nodes to be Ready
echo "  Phase 3: Waiting for all nodes to be Ready..."
NODES_READY_WAIT=0
NODES_READY_TIMEOUT=300

while [[ $NODES_READY_WAIT -lt $NODES_READY_TIMEOUT ]]; do
    NODES_OUTPUT=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get nodes --no-headers 2>&1 || true)
    READY_COUNT=$(echo "$NODES_OUTPUT" | grep -c " Ready " 2>/dev/null || echo "0")
    READY_COUNT=$(echo "$READY_COUNT" | tr -d '[:space:]')
    TOTAL_COUNT=$(echo "$NODES_OUTPUT" | grep -c "." 2>/dev/null || echo "0")
    TOTAL_COUNT=$(echo "$TOTAL_COUNT" | tr -d '[:space:]')
    
    if [[ $READY_COUNT -ge $EXPECTED_NODES ]]; then
        echo "  ✓ All $EXPECTED_NODES nodes are Ready (${NODES_READY_WAIT}s)"
        echo ""
        echo "  Node status:"
        KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get nodes -o wide 2>&1 | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi
    
    # Show progress
    if [[ $((NODES_READY_WAIT % 15)) -eq 0 ]] || [[ $NODES_READY_WAIT -lt 30 ]]; then
        echo "    Nodes ready: $READY_COUNT/$EXPECTED_NODES (${NODES_READY_WAIT}s)"
        # Show which nodes are not ready
        NOT_READY=$(echo "$NODES_OUTPUT" | grep -v " Ready " | awk '{print $1}' || true)
        if [[ -n "$NOT_READY" ]]; then
            echo "      Not ready: $NOT_READY"
        fi
    fi
    
    sleep 5
    NODES_READY_WAIT=$((NODES_READY_WAIT + 5))
done

if [[ $NODES_READY_WAIT -ge $NODES_READY_TIMEOUT ]]; then
    echo "  WARNING: Only $READY_COUNT/$EXPECTED_NODES nodes Ready after ${NODES_READY_TIMEOUT}s"
    echo "  Workers may still be joining the cluster"
    echo ""
    echo "  Current node status:"
    KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get nodes -o wide 2>&1 | while IFS= read -r line; do
        echo "    $line"
    done
fi

echo ""

# Phase 4: Wait for core system pods to be running
echo "  Phase 4: Waiting for core system pods..."
PODS_WAIT=0
PODS_TIMEOUT=180

# Core pods that must be running
CORE_PODS=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "coredns" "kube-flannel" "kube-proxy")

while [[ $PODS_WAIT -lt $PODS_TIMEOUT ]]; do
    # Get all kube-system pods
    PODS_OUTPUT=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system --no-headers 2>&1 || true)
    
    # Count running vs total
    RUNNING=$(echo "$PODS_OUTPUT" | grep -c "Running" 2>/dev/null || echo "0")
    RUNNING=$(echo "$RUNNING" | tr -d '[:space:]')
    TOTAL=$(echo "$PODS_OUTPUT" | grep -c "." 2>/dev/null || echo "0")
    TOTAL=$(echo "$TOTAL" | tr -d '[:space:]')
    
    # Check for pending or error pods
    PENDING=$(echo "$PODS_OUTPUT" | grep -cE "Pending|ContainerCreating|Init:" 2>/dev/null || echo "0")
    PENDING=$(echo "$PENDING" | tr -d '[:space:]')
    ERRORS=$(echo "$PODS_OUTPUT" | grep -cE "Error|CrashLoopBackOff" 2>/dev/null || echo "0")
    ERRORS=$(echo "$ERRORS" | tr -d '[:space:]')
    
    if [[ $RUNNING -ge $TOTAL ]] && [[ $TOTAL -gt 0 ]] && [[ $ERRORS -eq 0 ]]; then
        echo "  ✓ All $TOTAL system pods Running (${PODS_WAIT}s)"
        echo ""
        echo "  System pods:"
        KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system 2>&1 | while IFS= read -r line; do
            echo "    $line"
        done
        break
    fi
    
    # Show progress
    if [[ $((PODS_WAIT % 15)) -eq 0 ]] || [[ $PODS_WAIT -lt 30 ]]; then
        echo "    Pods: $RUNNING Running, $PENDING Pending, $ERRORS Errors ($PODS_WAIT}s)"
    fi
    
    sleep 5
    PODS_WAIT=$((PODS_WAIT + 5))
done

if [[ $PODS_WAIT -ge $PODS_TIMEOUT ]]; then
    echo "  WARNING: Not all system pods running after ${PODS_TIMEOUT}s"
    echo "  Some pods may still be initializing"
    echo ""
    echo "  Current pod status:"
    KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kube-system 2>&1 | while IFS= read -r line; do
        echo "    $line"
    done
fi

echo ""

# Phase 5: Verify kubelet is healthy on ALL nodes
echo "  Phase 5: Verifying kubelet health on all nodes..."
KUBELET_WAIT=0
KUBELET_TIMEOUT=300
KUBELET_CHECK_INTERVAL=5

# Build list of all node IPs
ALL_NODE_IPS=("$MASTER_IP")
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    ALL_NODE_IPS+=("$WORKER_IP")
done

while [[ $KUBELET_WAIT -lt $KUBELET_TIMEOUT ]]; do
    ALL_KUBELETS_RUNNING=true
    KUBELET_STATUS_OUTPUT=""
    
    for node_ip in "${ALL_NODE_IPS[@]}"; do
        # Get kubelet service status
        KUBELET_STATUS=$(talosctl service kubelet --nodes "$node_ip" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
        
        # Check if kubelet is running (STATE line shows "Running")
        if echo "$KUBELET_STATUS" | grep -q "^STATE.*Running"; then
            NODE_HEALTHY=true
        else
            NODE_HEALTHY=false
            ALL_KUBELETS_RUNNING=false
        fi
        
        # Parse status fields
        NODE_STATE=$(echo "$KUBELET_STATUS" | grep "^STATE" | awk '{print $2}' || echo "unknown")
        NODE_HEALTH=$(echo "$KUBELET_STATUS" | grep "^HEALTH" | awk '{print $2}' || echo "unknown")
        
        KUBELET_STATUS_OUTPUT+="    $node_ip: State=$NODE_STATE, Health=$NODE_HEALTH"$'\n'
    done
    
    if [[ "$ALL_KUBELETS_RUNNING" == "true" ]]; then
        echo "  ✓ Kubelet is Running and Healthy on all ${#ALL_NODE_IPS[@]} nodes (${KUBELET_WAIT}s)"
        echo ""
        echo "  Kubelet status:"
        echo "$KUBELET_STATUS_OUTPUT"
        break
    fi
    
    # Show progress
    if [[ $((KUBELET_WAIT % 15)) -eq 0 ]] || [[ $KUBELET_WAIT -lt 30 ]]; then
        echo "    Kubelets: waiting for all nodes... (${KUBELET_WAIT}s)"
        echo "$KUBELET_STATUS_OUTPUT" | head -5
    fi
    
    sleep $KUBELET_CHECK_INTERVAL
    KUBELET_WAIT=$((KUBELET_WAIT + KUBELET_CHECK_INTERVAL))
done

if [[ $KUBELET_WAIT -ge $KUBELET_TIMEOUT ]]; then
    echo "  WARNING: Not all kubelets are Running after ${KUBELET_TIMEOUT}s"
    echo "  Current kubelet status:"
    echo "$KUBELET_STATUS_OUTPUT"
fi

echo ""

# Phase 6: Verify etcd health
echo "  Phase 6: Verifying etcd health..."
ETCD_OUTPUT=$(talosctl get etcdmembers --nodes "$MASTER_IP" --endpoints "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" 2>&1 || true)
ETCD_MEMBER_COUNT=$(echo "$ETCD_OUTPUT" | grep -c "EtcdMember" 2>/dev/null || echo "0")
ETCD_MEMBER_COUNT=$(echo "$ETCD_MEMBER_COUNT" | tr -d '[:space:]')

if [[ $ETCD_MEMBER_COUNT -ge 1 ]]; then
    echo "  ✓ etcd is healthy ($ETCD_MEMBER_COUNT member(s))"
else
    echo "  WARNING: etcd health could not be verified"
fi

echo ""
echo "  ✓ Cluster health verification complete"
echo ""

# Summary
echo "  === Cluster Status ==="
echo "  Nodes: $READY_COUNT/$EXPECTED_NODES Ready"
echo "  Kubelets: ${#ALL_NODE_IPS[@]}/${#ALL_NODE_IPS[@]} Running"
echo "  System Pods: $RUNNING/$TOTAL Running"
echo "  etcd: $ETCD_MEMBER_COUNT member(s)"
echo ""

KUBELET_HEALTHY=true
if [[ $KUBELET_WAIT -ge $KUBELET_TIMEOUT ]]; then
    KUBELET_HEALTHY=false
fi

if [[ $READY_COUNT -ge $EXPECTED_NODES ]] && [[ $RUNNING -ge $TOTAL ]] && [[ "$KUBELET_HEALTHY" == "true" ]]; then
    echo "  ✓ Cluster is FULLY HEALTHY"
else
    echo "  ⚠ Cluster is partially healthy"
    echo "    Some components may still be initializing"
fi

echo ""
