#!/bin/bash
# =============================================================================
# Istio Step 05: Configure Istio + Envoy Gateway Integration
# =============================================================================
# Wires Envoy Gateway to work with the Istio service mesh:
#   - Labels namespaces for sidecar injection
#   - Configures mTLS between Envoy Gateway and mesh services
#   - Creates a sample HTTPRoute for Envoy Gateway → mesh routing
#   - Enables Istio ingress gateway (optional)
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[5/7] Configuring Istio + Envoy Gateway integration..."
echo ""

# =============================================================================
# Label default namespace for sidecar injection
# =============================================================================
echo -n "  Labeling default namespace for Istio sidecar injection... "
kubectl label namespace default istio-injection=enabled --overwrite &>/dev/null
echo "✓"

# Label the envoy-gateway-system namespace (control plane doesn't need injection,
# but we label it so future data-plane components can participate)
echo -n "  Labeling $ENVOY_GATEWAY_NAMESPACE for Istio sidecar injection... "
kubectl label namespace "$ENVOY_GATEWAY_NAMESPACE" istio-injection=enabled --overwrite &>/dev/null || true
echo "✓ (control-plane pods use annotations to opt out)"

# Annotate envoy-gateway deployment to opt out of sidecar injection
# (the control plane doesn't need an Envoy sidecar)
echo -n "  Opting envoy-gateway control-plane out of sidecar injection... "
kubectl annotate deployment -n "$ENVOY_GATEWAY_NAMESPACE" envoy-gateway \
    sidecar.istio.io/inject="false" --overwrite &>/dev/null || true
echo "✓"

# =============================================================================
# PeerAuthentication for mTLS
# =============================================================================
echo -n "  Configuring PERMISSIVE mTLS (allows both mesh and non-mesh traffic)... "
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE
EOF
echo "✓"

# =============================================================================
# Create a sample HTTPRoute to demonstrate Envoy Gateway → Istio mesh routing
# =============================================================================
echo ""
echo "  Sample HTTPRoute (for future application deployment):"
echo "    - Will not apply yet (requires an actual backend service)"
echo "    - Creates HTTPRoute in envoy-gateway-system namespace"
echo ""
echo "  To test the integration after deploying an app:"
echo "    ---"
echo "    apiVersion: gateway.networking.k8s.io/v1"
echo "    kind: HTTPRoute"
echo "    metadata:"
echo "      name: app-route"
echo "      namespace: $ENVOY_GATEWAY_NAMESPACE"
echo "    spec:"
echo "      parentRefs:"
echo "        - name: envoy-gateway"
echo "      rules:"
echo "        - backendRefs:"
echo "            - name: my-service"
echo "              port: 80"
echo "    ---"
echo ""

# =============================================================================
# Create a DestinationRule to enable mTLS from EG to mesh services
# =============================================================================
echo -n "  Creating DestinationRule for mesh-wide mTLS... "
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: default
  namespace: istio-system
spec:
  host: "*.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
EOF
echo "✓"

# =============================================================================
# Install Istio ingress gateway (optional)
# =============================================================================
if [[ "$ISTIO_INGRESS_ENABLED" == "true" ]]; then
    echo ""
    echo "  Installing Istio ingress gateway (optional)..."
    echo -n "  Installing istio-ingressgateway... "
    if helm upgrade --install istio-ingressgateway istio/gateway \
        --namespace "$ISTIO_NAMESPACE" \
        --wait \
        --timeout 180s \
        --set service.type=LoadBalancer \
        --set autoscaleMin=1 \
        --set autoscaleMax=3 \
        2>/dev/null; then
        echo "✓"
        echo ""
        echo "  Istio ingress gateway pods:"
        kubectl get pods -n "$ISTIO_NAMESPACE" -l app=istio-ingressgateway
    else
        echo "✗ Failed to install Istio ingress gateway"
    fi
else
    echo ""
    echo "  Istio ingress gateway: disabled (using Envoy Gateway for ingress)"
fi

echo ""
echo "Integration configuration complete"
echo ""
