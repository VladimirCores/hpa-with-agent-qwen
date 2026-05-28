#!/bin/bash
# =============================================================================
# Step 05: Verify Installation
# =============================================================================
# Verifies all installed components and provides a summary.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Accept installed components as arguments
INSTALLED_CNI="${1:-cilium}"
INSTALLED_METRICS="${2:-false}"
INSTALLED_METALLB="${3:-false}"

echo "[5/5] Verifying installation..."
echo ""

# =============================================================================
# Verify CNI
# =============================================================================
echo "CNI Status ($INSTALLED_CNI):"
case "$INSTALLED_CNI" in
    cilium)
        if kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null; then
            CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
            CILIUM_READY=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep "Running" | wc -l || true)
            echo "  ✓ Cilium: $CILIUM_READY/$CILIUM_PODS pods ready"
            
            # Check kube-proxy replacement status
            if ! kubectl get daemonset kube-proxy -n kube-system &>/dev/null; then
                echo "  ✓ kube-proxy replacement: enabled (BPF-based service routing)"
            else
                echo "  ✗ kube-proxy still running (should have been replaced by Cilium)"
            fi
            
            # Check Hubble
            if kubectl get pods -n kube-system -l k8s-app=hubble-ui &>/dev/null; then
                HUBBLE_PODS=$(kubectl get pods -n kube-system -l k8s-app=hubble-ui --no-headers 2>/dev/null | wc -l)
                echo "  ✓ Hubble UI: $HUBBLE_PODS pods running"
                echo "    Access: kubectl port-forward -n kube-system svc/hubble-ui 8080:80"
            fi
            
            if kubectl get pods -n kube-system -l k8s-app=hubble-relay &>/dev/null; then
                RELAY_PODS=$(kubectl get pods -n kube-system -l k8s-app=hubble-relay --no-headers 2>/dev/null | wc -l)
                echo "  ✓ Hubble Relay: $RELAY_PODS pods running"
            fi
        else
            echo "  ✗ Cilium not found"
        fi
        ;;
    calico)
        if kubectl get pods -n calico-system -l k8s-app=calico-node &>/dev/null; then
            CALICO_PODS=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
            CALICO_READY=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep "Running" | wc -l || true)
            echo "  ✓ Calico: $CALICO_READY/$CALICO_PODS pods ready"
        else
            echo "  ✗ Calico not found"
        fi
        ;;
    flannel)
        if kubectl get pods -n kube-system -l app=flannel &>/dev/null; then
            FLANNEL_PODS=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | wc -l)
            FLANNEL_READY=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | grep "Running" | wc -l || true)
            echo "  ✓ Flannel: $FLANNEL_READY/$FLANNEL_PODS pods ready"
        else
            echo "  ✗ Flannel not found"
        fi
        ;;
esac
echo ""

# =============================================================================
# Verify Metrics Server
# =============================================================================
if [[ "$INSTALLED_METRICS" == "true" ]]; then
    echo "Metrics Server Status:"
    if kubectl get pods -n kube-system -l k8s-app=metrics-server &>/dev/null; then
        MS_PODS=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | wc -l)
        MS_READY=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | grep "Running" | wc -l || true)
        echo "  ✓ Metrics-server: $MS_READY/$MS_PODS pods ready"
        
        # Test metrics API
        sleep 5
        if kubectl top nodes &>/dev/null; then
            echo "  ✓ Metrics API: working"
        else
            echo "  ⚠ Metrics API: not yet available (may take 1-2 minutes)"
        fi
    else
        echo "  ✗ Metrics-server not found"
    fi
    echo ""
fi

# =============================================================================
# Verify MetalLB
# =============================================================================
if [[ "$INSTALLED_METALLB" == "true" ]]; then
    echo "MetalLB Status:"
    if kubectl get namespace metallb-system &>/dev/null; then
        METALLB_PODS=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | wc -l)
        METALLB_READY=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | grep "Running" | wc -l || true)
        echo "  ✓ MetalLB: $METALLB_READY/$METALLB_PODS pods ready"
        
        # Check IP pools
        echo "  IP Pools:"
        kubectl get ipaddresspool -n metallb-system -o custom-columns="NAME:.metadata.name,ADDRESSES:.spec.addresses" 2>/dev/null | tail -n +2 | while read -r line; do
            echo "    - $line"
        done
        
        # Check advertisements
        ADV_COUNT=$(kubectl get l2advertisement -n metallb-system --no-headers 2>/dev/null | wc -l || true)
        if (( ADV_COUNT > 0 )); then
            echo "  ✓ L2 Advertisements: $ADV_COUNT configured"
        fi
        
        BGP_ADV_COUNT=$(kubectl get bgpadvertisement -n metallb-system --no-headers 2>/dev/null | wc -l || true)
        if (( BGP_ADV_COUNT > 0 )); then
            echo "  ✓ BGP Advertisements: $BGP_ADV_COUNT configured"
        fi
        
        # Check for Envoy Gateway pool
        if kubectl get ipaddresspool envoy-gateway-pool -n metallb-system &>/dev/null; then
            echo "  ✓ Envoy Gateway dedicated pool: configured"
        fi
    else
        echo "  ✗ MetalLB namespace not found"
    fi
    echo ""
fi

# =============================================================================
# Cluster Overview
# =============================================================================
echo "Cluster Overview:"
echo ""
echo "Nodes:"
kubectl get nodes -o wide 2>/dev/null || echo "  (unable to retrieve)"
echo ""

echo "System Pods:"
kubectl get pods -n kube-system --sort-by='.metadata.creationTimestamp' 2>/dev/null | tail -20 || echo "  (unable to retrieve)"
echo ""

if [[ "$INSTALLED_METALLB" == "true" ]]; then
    echo "MetalLB Pods:"
    kubectl get pods -n metallb-system 2>/dev/null || echo "  (unable to retrieve)"
    echo ""
fi

# =============================================================================
# Summary
# =============================================================================
echo "═══════════════════════════════════════════════════════════"
echo "  Installation Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Installed components:"
echo "  ✓ $INSTALLED_CNI CNI"
if [[ "$INSTALLED_METRICS" == "true" ]]; then
    echo "  ✓ metrics-server"
fi
if [[ "$INSTALLED_METALLB" == "true" ]]; then
    echo "  ✓ MetalLB LoadBalancer ($METALLB_IP_POOL_START-$METALLB_IP_POOL_END)"
    if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
        echo "  ✓ Envoy Gateway dedicated IP: $ENVOY_GATEWAY_LB_IP"
    fi
fi
echo ""
echo "Next steps:"
echo "  1. Test CNI:"
echo "     kubectl run test --image=nginx --restart=Never"
echo "     kubectl get pods -o wide"
echo ""
if [[ "$INSTALLED_METRICS" == "true" ]]; then
    echo "  2. Test metrics (for HPA):"
    echo "     kubectl top nodes"
    echo "     kubectl top pods -A"
    echo ""
fi
if [[ "$INSTALLED_METALLB" == "true" ]]; then
    echo "  3. Test MetalLB LoadBalancer:"
    echo "     kubectl apply -f docs/examples/loadbalancer-test.yaml"
    echo "     kubectl get svc -w"
    echo ""
    echo "  4. Install Istio with Envoy Gateway (optional):"
    echo "     ./scripts/istio-install.sh"
    echo ""
    echo "  5. See docs/09-MetalLB-LoadBalancer.md for usage examples"
    echo ""
fi
echo "═══════════════════════════════════════════════════════════"
echo ""
