#!/bin/bash
# =============================================================================
# Kubernetes Components - Common Setup
# =============================================================================
# Common setup for all k8s-components steps.
# Sources .env file and sets up common variables.
# =============================================================================

set -euo pipefail

# Get script directory and project root
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$STEP_DIR")")"

# Source .env file if not already sourced
if [[ -z "${NETWORK_NAME:-}" ]]; then
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
    else
        echo "ERROR: .env file not found in $PROJECT_ROOT" >&2
        exit 1
    fi
fi

# Set defaults
CILIUM_VERSION="${CILIUM_VERSION:-1.19.1}"
CALICO_VERSION="${CALICO_VERSION:-3.28.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-0.7.1}"

# Cilium configuration (kube-proxy replacement always enabled)
CILIUM_HUBBLE_RELAY_ENABLED="${CILIUM_HUBBLE_RELAY_ENABLED:-true}"
HUBBLE_ENABLED="${HUBBLE_ENABLED:-true}"
KIALA_ENABLED="${KIALA_ENABLED:-false}"

# MetalLB defaults
METALLB_VERSION="${METALLB_VERSION:-0.14.8}"
METALLB_INSTALL_METHOD="${METALLB_INSTALL_METHOD:-helm}"
METALLB_IP_POOL_NAME="${METALLB_IP_POOL_NAME:-default-pool}"
METALLB_IP_POOL_START="${METALLB_IP_POOL_START:-192.168.123.200}"
METALLB_IP_POOL_END="${METALLB_IP_POOL_END:-192.168.123.250}"
METALLB_MODE="${METALLB_MODE:-l2}"
METALLB_L2_INTERFACES="${METALLB_L2_INTERFACES:-}"
METALLB_L2_NODE_SELECTOR="${METALLB_L2_NODE_SELECTOR:-}"
METALLB_BGP_MY_ASN="${METALLB_BGP_MY_ASN:-64512}"
METALLB_BGP_PEER_ASN="${METALLB_BGP_PEER_ASN:-64512}"
METALLB_BGP_PEER_ADDRESS="${METALLB_BGP_PEER_ADDRESS:-}"
METALLB_BGP_PEER_PORT="${METALLB_BGP_PEER_PORT:-179}"
METALLB_AVOID_BUGGY_IPS="${METALLB_AVOID_BUGGY_IPS:-true}"
METALLB_AUTO_ASSIGN="${METALLB_AUTO_ASSIGN:-true}"
ENVOY_GATEWAY_LB_IP="${ENVOY_GATEWAY_LB_IP:-}"

# Expose internal services via MetalLB
EXPOSE_HUBBLE_UI="${EXPOSE_HUBBLE_UI:-true}"
HUBBLE_UI_LB_IP="${HUBBLE_UI_LB_IP:-}"
EXPOSE_K8S_DASHBOARD="${EXPOSE_K8S_DASHBOARD:-true}"
K8S_DASHBOARD_LB_IP="${K8S_DASHBOARD_LB_IP:-}"

# Istio + Envoy Gateway defaults (for --with-istio / --with-envoy-gateway)
ISTIO_VERSION="${ISTIO_VERSION:-1.22.0}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_PROFILE="${ISTIO_PROFILE:-default}"
ISTIO_INGRESS_ENABLED="${ISTIO_INGRESS_ENABLED:-false}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-1.1.0}"
ENVOY_GATEWAY_NAMESPACE="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
ENVOY_GATEWAY_REPLICAS="${ENVOY_GATEWAY_REPLICAS:-2}"
ENVOY_GATEWAY_LB_IP="${ENVOY_GATEWAY_LB_IP:-192.168.123.200}"

# Kubeconfig
DEFAULT_KUBECONFIG="$PROJECT_ROOT/talos-cluster/kubeconfig"

# Export common variables
export STEP_DIR
export PROJECT_ROOT
export CILIUM_VERSION
export CALICO_VERSION
export METRICS_SERVER_VERSION
export CILIUM_HUBBLE_RELAY_ENABLED
export HUBBLE_ENABLED
export KIALA_ENABLED
export METALLB_VERSION
export METALLB_INSTALL_METHOD
export METALLB_IP_POOL_NAME
export METALLB_IP_POOL_START
export METALLB_IP_POOL_END
export METALLB_MODE
export METALLB_L2_INTERFACES
export METALLB_L2_NODE_SELECTOR
export METALLB_BGP_MY_ASN
export METALLB_BGP_PEER_ASN
export METALLB_BGP_PEER_ADDRESS
export METALLB_BGP_PEER_PORT
export METALLB_AVOID_BUGGY_IPS
export METALLB_AUTO_ASSIGN
export ENVOY_GATEWAY_LB_IP
export EXPOSE_HUBBLE_UI
export HUBBLE_UI_LB_IP
export EXPOSE_K8S_DASHBOARD
export K8S_DASHBOARD_LB_IP
export ENVOY_GATEWAY_LB_IP
export DEFAULT_KUBECONFIG

# Export Istio + Envoy Gateway variables
export ISTIO_VERSION
export ISTIO_NAMESPACE
export ISTIO_PROFILE
export ISTIO_INGRESS_ENABLED
export ENVOY_GATEWAY_VERSION
export ENVOY_GATEWAY_NAMESPACE
export ENVOY_GATEWAY_REPLICAS
export ENVOY_GATEWAY_LB_IP
