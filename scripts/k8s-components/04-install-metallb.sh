#!/bin/bash
# =============================================================================
# Step 04: Install MetalLB LoadBalancer
# =============================================================================
# Installs MetalLB for LoadBalancer-type Services.
# Supports Layer 2 and BGP modes.
# Prepares for Envoy Gateway integration with dedicated IP pool.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[4/5] Installing MetalLB $METALLB_VERSION..."
echo ""

# Validate IP pool configuration
validate_ip_pool() {
    echo "  Validating IP pool configuration..."

    # Parse IP addresses
    IFS='.' read -r -a START_OCTETS <<< "$METALLB_IP_POOL_START"
    IFS='.' read -r -a END_OCTETS <<< "$METALLB_IP_POOL_END"

    # Validate IP range (start < end)
    if [[ ${START_OCTETS[3]} -ge ${END_OCTETS[3]} ]]; then
        echo "  ✗ Invalid IP range: start ($METALLB_IP_POOL_START) must be less than end ($METALLB_IP_POOL_END)"
        return 1
    fi

    # Calculate pool size
    local pool_size=$(( ${END_OCTETS[3]} - ${START_OCTETS[3]} + 1 ))
    if [[ $pool_size -lt 10 ]]; then
        echo "  ⚠ WARNING: IP pool size ($pool_size) is small (< 10 IPs)"
        echo "    Consider expanding the pool for better scalability"
    else
        echo "  ✓ IP pool size: $pool_size addresses"
    fi

    # Check for conflicts with static IPs
    local conflicts=0
    if [[ -n "${MASTER_IP:-}" ]]; then
        if [[ "$MASTER_IP" >= "$METALLB_IP_POOL_START" && "$MASTER_IP" <= "$METALLB_IP_POOL_END" ]]; then
            echo "  ✗ Master IP $MASTER_IP conflicts with MetalLB pool"
            conflicts=1
        fi
    fi

    # Check worker IPs
    for i in $(seq 1 $WORKER_COUNT); do
        WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
        if [[ "$WORKER_IP" >= "$METALLB_IP_POOL_START" && "$WORKER_IP" <= "$METALLB_IP_POOL_END" ]]; then
            echo "  ✗ Worker IP $WORKER_IP conflicts with MetalLB pool"
            conflicts=1
        fi
    done

    if [[ $conflicts -gt 0 ]]; then
        echo "  Remediation:"
        echo "    - Adjust METALLB_IP_POOL_START and METALLB_IP_POOL_END in .env"
        echo "    - Ensure pool doesn't overlap with node static IPs"
        return 1
    fi

    echo "  ✓ No IP conflicts detected"
    echo "  ✓ IP pool validation passed"
}

# Run validation
if ! validate_ip_pool; then
    echo ""
    echo "  ERROR: IP pool validation failed"
    exit 1
fi

echo ""
echo "  Configuration:"
echo "    IP Pool:      $METALLB_IP_POOL_START-$METALLB_IP_POOL_END"
echo "    Mode:         $METALLB_MODE"
echo "    Install:      $METALLB_INSTALL_METHOD"
if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
    echo "    Envoy GW IP:  $ENVOY_GATEWAY_LB_IP"
fi
echo ""

# =============================================================================
# Check if MetalLB already exists
# =============================================================================
if kubectl get namespace metallb-system &>/dev/null; then
    METALLB_PODS=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | wc -l)
    if (( METALLB_PODS > 0 )); then
        echo "  MetalLB already installed ($METALLB_PODS pods)"
        echo "  Checking configuration..."
        
        # Check if IP pool exists
        if kubectl get ipaddresspool -n metallb-system "$METALLB_IP_POOL_NAME" &>/dev/null; then
            echo "  ✓ IP pool '$METALLB_IP_POOL_NAME' configured"
            echo "  ✓ Skipped"
            exit 0
        else
            echo "  ⚠ IP pool not found, will create..."
        fi
    fi
fi

# =============================================================================
# Install MetalLB
# =============================================================================
if [[ "$METALLB_INSTALL_METHOD" == "helm" ]]; then
    echo "  Installing MetalLB via Helm..."
    
    # Check if helm is available
    if ! command -v helm &>/dev/null; then
        echo "  ERROR: helm not found"
        echo "  Install helm: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        echo ""
        echo "  Alternatively, use manifest installation:"
        echo "  Set METALLB_INSTALL_METHOD=manifest in .env"
        exit 1
    fi
    
    # Add and update Helm repo
    echo "  Adding MetalLB Helm repository..."
    helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
    helm repo update
    
    # Create namespace
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Install via Helm with configuration
    echo "  Installing MetalLB chart..."
    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --version "$METALLB_VERSION" \
        --set ipAddressPools[0].name="$METALLB_IP_POOL_NAME" \
        --set ipAddressPools[0].addresses[0]="$METALLB_IP_POOL_START-$METALLB_IP_POOL_END" \
        --set ipAddressPools[0].autoAssign="$METALLB_AUTO_ASSIGN" \
        --set ipAddressPools[0].avoidBuggyIPs="$METALLB_AVOID_BUGGY_IPS" \
        --set l2Advertisements[0].ipAddressPools[0]="$METALLB_IP_POOL_NAME" \
        --wait \
        --timeout 300s
    
else
    echo "  Installing MetalLB via manifests..."
    
    # Create namespace
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply MetalLB base manifests
    echo "  Applying MetalLB base manifests..."
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"
    
    # Wait for MetalLB pods
    echo "  Waiting for MetalLB controller..."
    kubectl wait --for=condition=ready pod -n metallb-system -l component=controller --timeout=120s 2>/dev/null || {
        echo "  WARNING: MetalLB controller not ready within timeout"
    }
fi

# =============================================================================
# Configure IPAddressPool and Advertisement (if not done via Helm)
# =============================================================================
if [[ "$METALLB_INSTALL_METHOD" == "manifest" ]]; then
    echo "  Creating IP address pool and advertisement..."
    
    # Create IPAddressPool
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${METALLB_IP_POOL_NAME}
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_IP_POOL_START}-${METALLB_IP_POOL_END}
  autoAssign: ${METALLB_AUTO_ASSIGN}
  avoidBuggyIPs: ${METALLB_AVOID_BUGGY_IPS}
EOF
    
    # Create L2Advertisement or BGPAdvertisement
    if [[ "$METALLB_MODE" == "l2" ]]; then
        echo "  Creating L2Advertisement..."
        L2_ADV_CONFIG=$(cat <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${METALLB_IP_POOL_NAME}-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - ${METALLB_IP_POOL_NAME}
EOF
)
        # Add interfaces if specified
        if [[ -n "$METALLB_L2_INTERFACES" ]]; then
            INTERFACES_YAML=$(echo "$METALLB_L2_INTERFACES" | tr ',' '\n' | sed 's/^/    - /' | tr '\n' '\n')
            L2_ADV_CONFIG="$L2_ADV_CONFIG
  interfaces:
$INTERFACES_YAML"
        fi
        
        # Add nodeSelector if specified
        if [[ -n "$METALLB_L2_NODE_SELECTOR" ]]; then
            L2_ADV_CONFIG="$L2_ADV_CONFIG
  nodeSelectors:
    - matchLabels:
        ${METALLB_L2_NODE_SELECTOR}"
        fi
        
        echo "$L2_ADV_CONFIG" | kubectl apply -f -
        
    elif [[ "$METALLB_MODE" == "bgp" ]]; then
        if [[ -z "$METALLB_BGP_PEER_ADDRESS" ]]; then
            echo "  ERROR: BGP mode requires METALLB_BGP_PEER_ADDRESS"
            exit 1
        fi
        
        echo "  Creating BGP peer and advertisement..."
        cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: ${METALLB_IP_POOL_NAME}-bgp-peer
  namespace: metallb-system
spec:
  myASN: ${METALLB_BGP_MY_ASN}
  peerASN: ${METALLB_BGP_PEER_ASN}
  peerAddress: ${METALLB_BGP_PEER_ADDRESS}
  peerPort: ${METALLB_BGP_PEER_PORT}
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: ${METALLB_IP_POOL_NAME}-bgp-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - ${METALLB_IP_POOL_NAME}
  peers:
    - ${METALLB_IP_POOL_NAME}-bgp-peer
EOF
    fi
fi

# =============================================================================
# Create dedicated IP pool for Envoy Gateway (if configured)
# =============================================================================
if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
    echo ""
    echo "  Creating dedicated IP pool for Envoy Gateway..."
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: envoy-gateway-pool
  namespace: metallb-system
spec:
  addresses:
    - ${ENVOY_GATEWAY_LB_IP}
  autoAssign: false
EOF
    
    # Create L2Advertisement for Envoy Gateway pool
    if [[ "$METALLB_MODE" == "l2" ]]; then
        cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: envoy-gateway-pool-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - envoy-gateway-pool
EOF
    fi
    
    echo "  ✓ Envoy Gateway IP pool created ($ENVOY_GATEWAY_LB_IP)"
    echo "    Use annotation: metallb.universe.tf/address-pool: envoy-gateway-pool"
fi

# =============================================================================
# Wait for MetalLB pods
# =============================================================================
echo ""
echo "  Waiting for MetalLB pods..."
sleep 5
kubectl wait --for=condition=ready pod -n metallb-system -l component=controller --timeout=120s 2>/dev/null || {
    echo "  WARNING: MetalLB controller not ready within timeout"
}
kubectl wait --for=condition=ready pod -n metallb-system -l component=speaker --timeout=120s 2>/dev/null || {
    echo "  WARNING: MetalLB speaker not ready within timeout"
}

echo ""
echo "  ✓ MetalLB installed"
echo ""
echo "  IP Address Pool: $METALLB_IP_POOL_NAME ($METALLB_IP_POOL_START-$METALLB_IP_POOL_END)"
echo "  Mode: $METALLB_MODE"
if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
    echo "  Envoy Gateway Pool: envoy-gateway-pool ($ENVOY_GATEWAY_LB_IP)"
fi
echo ""

# =============================================================================
# Expose Hubble UI via MetalLB LoadBalancer
# =============================================================================
if [[ "$EXPOSE_HUBBLE_UI" == "true" ]]; then
    echo "  Exposing Hubble UI via MetalLB LoadBalancer..."
    
    # Check if Hubble UI service exists
    if kubectl get svc hubble-ui -n kube-system &>/dev/null; then
        # Build LoadBalancer service patch
        if [[ -n "$HUBBLE_UI_LB_IP" ]]; then
            echo "  Assigning static IP: $HUBBLE_UI_LB_IP"
            kubectl patch svc hubble-ui -n kube-system -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"$HUBBLE_UI_LB_IP\"}}" 2>/dev/null || true
        else
            kubectl patch svc hubble-ui -n kube-system -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
        fi
        
        # Wait for external IP
        echo "  Waiting for Hubble UI external IP..."
        sleep 5
        for i in {1..10}; do
            HUBBLE_EXT_IP=$(kubectl get svc hubble-ui -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
            if [[ -n "$HUBBLE_EXT_IP" ]]; then
                break
            fi
            sleep 2
        done
        
        if [[ -n "$HUBBLE_EXT_IP" ]]; then
            echo "  ✓ Hubble UI exposed at: http://$HUBBLE_EXT_IP"
        else
            echo "  ⚠ Hubble UI external IP not yet assigned (checking status)"
            HUBBLE_EXT_IP=$(kubectl get svc hubble-ui -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
            echo "    Current status: $HUBBLE_EXT_IP"
        fi
    else
        echo "  ⚠ Hubble UI service not found (Hubble may not be installed)"
        echo "    Enable Hubble: CILIUM_HUBBLE_ENABLED=true in .env"
    fi
    echo ""
fi

# =============================================================================
# Expose Kubernetes Dashboard via MetalLB LoadBalancer
# =============================================================================
if [[ "$EXPOSE_K8S_DASHBOARD" == "true" ]]; then
    echo "  Exposing Kubernetes Dashboard via MetalLB LoadBalancer..."
    
    # Check if Kubernetes Dashboard service exists
    if kubectl get svc kubernetes-dashboard -n kubernetes-dashboard &>/dev/null; then
        # Build LoadBalancer service patch
        if [[ -n "$K8S_DASHBOARD_LB_IP" ]]; then
            echo "  Assigning static IP: $K8S_DASHBOARD_LB_IP"
            kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"$K8S_DASHBOARD_LB_IP\",\"ports\":[{\"port\":443,\"targetPort\":8443}]}}" 2>/dev/null || true
        else
            kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"LoadBalancer","ports":[{"port":443,"targetPort":8443}]}}' 2>/dev/null || true
        fi
        
        # Wait for external IP
        echo "  Waiting for Kubernetes Dashboard external IP..."
        sleep 5
        for i in {1..10}; do
            DASHBOARD_EXT_IP=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
            if [[ -n "$DASHBOARD_EXT_IP" ]]; then
                break
            fi
            sleep 2
        done
        
        if [[ -n "$DASHBOARD_EXT_IP" ]]; then
            echo "  ✓ Kubernetes Dashboard exposed at: https://$DASHBOARD_EXT_IP"
            echo "    Login token: kubectl -n kubernetes-dashboard create token admin-user"
        else
            echo "  ⚠ Kubernetes Dashboard external IP not yet assigned (checking status)"
            DASHBOARD_EXT_IP=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
            echo "    Current status: $DASHBOARD_EXT_IP"
        fi
    else
        echo "  ⚠ Kubernetes Dashboard service not found"
        echo "    Install dashboard: ./scripts/talos-bootstrap.sh"
    fi
    echo ""
fi

# =============================================================================
# Print Access Instructions
# =============================================================================
if [[ "$EXPOSE_HUBBLE_UI" == "true" ]] || [[ "$EXPOSE_K8S_DASHBOARD" == "true" ]]; then
    echo "═══════════════════════════════════════════════════════════"
    echo "  External Service Access via MetalLB"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if [[ "$EXPOSE_HUBBLE_UI" == "true" ]]; then
        HUBBLE_IP=$(kubectl get svc hubble-ui -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        echo "  Hubble UI (Network Observability):"
        echo "    URL: http://$HUBBLE_IP"
        echo "    Status: $HUBBLE_IP"
        echo ""
    fi
    
    if [[ "$EXPOSE_K8S_DASHBOARD" == "true" ]]; then
        DASHBOARD_IP=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        echo "  Kubernetes Dashboard (Cluster Management):"
        echo "    URL: https://$DASHBOARD_IP"
        echo "    Status: $DASHBOARD_IP"
        echo "    Token: kubectl -n kubernetes-dashboard create token admin-user"
        echo ""
    fi
    
    echo "═══════════════════════════════════════════════════════════"
    echo ""
fi
