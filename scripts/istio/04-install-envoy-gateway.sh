#!/bin/bash
# =============================================================================
# Istio Step 04: Install Envoy Gateway
# =============================================================================
# Installs Envoy Gateway as a standalone Gateway API implementation.
# The Gateway is exposed via MetalLB LoadBalancer.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/7] Installing Envoy Gateway..."
echo ""

# Add/update Envoy Gateway Helm repo
echo -n "  Adding/updating Envoy Gateway Helm repository... "
helm repo add envoy-gateway https://gateway.envoyproxy.io/helm-charts 2>/dev/null || true
helm repo update 2>/dev/null
echo "✓"

# Create namespace if needed
echo -n "  Creating namespace $ENVOY_GATEWAY_NAMESPACE... "
kubectl create namespace "$ENVOY_GATEWAY_NAMESPACE" 2>/dev/null || true
echo "✓"

# Install Envoy Gateway via Helm
echo -n "  Installing Envoy Gateway... "
if helm upgrade --install envoy-gateway envoy-gateway/envoy-gateway \
    --namespace "$ENVOY_GATEWAY_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 300s \
    --set config.envoyGateway.provider.type="Kubernetes" \
    --set kubernetes.apis.gatewayApi="true" \
    --set kubernetes.apis.envoyExtension="true" \
    --set kubernetes.apis.rateLimit="true" \
    --set deployment.replicas="$ENVOY_GATEWAY_REPLICAS" \
    2>/dev/null; then
    echo "✓"
else
    echo "ERROR: Failed to install Envoy Gateway"
    exit 1
fi

# Wait for deployment
echo -n "  Waiting for Envoy Gateway deployment to be ready... "
if kubectl wait deployment -n "$ENVOY_GATEWAY_NAMESPACE" envoy-gateway --for=condition=Available --timeout=180s &>/dev/null; then
    echo "✓"
else
    echo "ERROR: envoy-gateway did not become ready"
    exit 1
fi

# Create GatewayClass
echo -n "  Creating GatewayClass (envoy-gateway)... "
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
echo "✓"

# Create Gateway with MetalLB LoadBalancer
echo -n "  Creating Gateway (envoy-gateway) with LoadBalancer IP $ENVOY_GATEWAY_LB_IP... "
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: envoy-gateway
  namespace: "$ENVOY_GATEWAY_NAMESPACE"
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
  addresses:
    - value: $ENVOY_GATEWAY_LB_IP
      type: IPAddress
EOF
echo "✓"

# Show Envoy Gateway pods
echo ""
echo "Envoy Gateway pods:"
kubectl get pods -n "$ENVOY_GATEWAY_NAMESPACE"
echo ""

echo "Envoy Gateway installation complete"
echo ""
