#!/bin/bash
# =============================================================================
# Istio Step 07: Verify Installation
# =============================================================================
# Verifies all Istio + Envoy Gateway components and provides access info.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[7/7] Verifying Istio + Envoy Gateway installation..."
echo ""

# =============================================================================
# Istio Control Plane
# =============================================================================
echo "Istio Control Plane:"
if kubectl get namespace "$ISTIO_NAMESPACE" &>/dev/null; then
    echo "  ✓ Namespace: $ISTIO_NAMESPACE"

    # Check istiod
    if kubectl get deployment istiod -n "$ISTIO_NAMESPACE" &>/dev/null; then
        IOD_READY=$(kubectl get deployment istiod -n "$ISTIO_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        IOD_DESIRED=$(kubectl get deployment istiod -n "$ISTIO_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
        echo "  ✓ istiod: $IOD_READY/$IOD_DESIRED replicas ready"
    else
        echo "  ✗ istiod: not found"
    fi

    # Check Istio CRDs
    CRD_COUNT=$(kubectl get crd -l app.kubernetes.io/part-of=istio --no-headers 2>/dev/null | wc -l || echo 0)
    if (( CRD_COUNT > 0 )); then
        echo "  ✓ Istio CRDs: $CRD_COUNT installed"
    else
        echo "  ⚠ Istio CRDs: none found"
    fi

    # Show Istio pods
    echo ""
    echo "  Istio pods ($ISTIO_NAMESPACE):"
    kubectl get pods -n "$ISTIO_NAMESPACE" 2>/dev/null || echo "    (none)"
else
    echo "  ✗ Istio namespace not found"
fi
echo ""

# =============================================================================
# Envoy Gateway
# =============================================================================
echo "Envoy Gateway:"
if kubectl get namespace "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null; then
    echo "  ✓ Namespace: $ENVOY_GATEWAY_NAMESPACE"

    if kubectl get deployment envoy-gateway -n "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null; then
        EG_READY=$(kubectl get deployment envoy-gateway -n "$ENVOY_GATEWAY_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        echo "  ✓ envoy-gateway: $EG_READY replicas ready"
    else
        echo "  ✗ envoy-gateway: not found"
    fi

    # Show Envoy Gateway pods
    echo ""
    echo "  Envoy Gateway pods ($ENVOY_GATEWAY_NAMESPACE):"
    kubectl get pods -n "$ENVOY_GATEWAY_NAMESPACE" 2>/dev/null || echo "    (none)"
else
    echo "  ✗ Envoy Gateway namespace not found"
fi
echo ""

# =============================================================================
# Gateway API Resources
# =============================================================================
echo "Gateway API Resources:"
if kubectl get gatewayclasses &>/dev/null 2>&1; then
    echo "  ✓ GatewayClass:"
    kubectl get gatewayclasses 2>/dev/null | tail -n +2 | while read -r line; do
        echo "    - $line"
    done
else
    echo "  ✗ No GatewayClasses found"
fi

if kubectl get gateways -n "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null 2>&1; then
    echo "  ✓ Gateways:"
    kubectl get gateways -n "$ENVOY_GATEWAY_NAMESPACE" 2>/dev/null | tail -n +2 | while read -r line; do
        echo "    - $line"
    done
else
    echo "  ⚠ No Gateways found"
fi
echo ""

# =============================================================================
# Sidecar Injection
# =============================================================================
echo "Sidecar Injection:"
INJECTED_NS=$(kubectl get namespace -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [[ -n "$INJECTED_NS" ]]; then
    echo "  ✓ Namespaces with istio-injection=enabled:"
    for ns in $INJECTED_NS; do
        echo "    - $ns"
    done
else
    echo "  ⚠ No namespaces labeled for sidecar injection"
fi
echo ""

# =============================================================================
# Kiali (if installed)
# =============================================================================
if kubectl get deployment kiali -n "$ISTIO_NAMESPACE" &>/dev/null 2>&1; then
    echo "Kiali:"
    KIALI_READY=$(kubectl get deployment kiali -n "$ISTIO_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    echo "  ✓ kiali: $KIALI_READY replicas ready"
    echo ""
fi

# =============================================================================
# Summary and Access Info
# =============================================================================
echo "═══════════════════════════════════════════════════════════"
echo "  Installation Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Installed components:"
if kubectl get namespace "$ISTIO_NAMESPACE" &>/dev/null; then
    echo "  ✓ Istio (istiod) — Service mesh control plane"
fi
if kubectl get namespace "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null; then
    echo "  ✓ Envoy Gateway — Ingress gateway (Gateway API)"
fi
if kubectl get deployment kiali -n "$ISTIO_NAMESPACE" &>/dev/null 2>&1; then
    echo "  ✓ Kiali — Service mesh visualization"
fi
echo ""
echo "Access URLs:"
echo "  Envoy Gateway (via MetalLB):  http://$ENVOY_GATEWAY_LB_IP"
echo "  Kiali:                        kubectl port-forward -n $ISTIO_NAMESPACE svc/kiali 20001:20001"
echo "  Grafana (if installed):       kubectl port-forward -n $ISTIO_NAMESPACE svc/grafana 3000:3000"
echo ""
echo "Quick verification:"
echo "  # Check Istio proxy status"
echo "  istioctl proxy-status  # (requires istioctl CLI)"
echo ""
echo "  # Test Envoy Gateway connectivity"
echo "  curl -v http://$ENVOY_GATEWAY_LB_IP  # Should return 503 (no routes configured)"
echo ""
echo "  # Check sidecar injection is working"
echo "  kubectl get pods -n default -o jsonpath='{range .items[*]}{.metadata.name}{\" → \"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo ""

# Check if any services have LoadBalancer IP
echo "LoadBalancer Services:"
kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null | tail -n +2 | while read -r line; do
    echo "  - $line"
done || echo "  (none)"
echo ""

echo "═══════════════════════════════════════════════════════════"
echo ""
