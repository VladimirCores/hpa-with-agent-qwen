#!/bin/bash
# =============================================================================
# Istio + Envoy Gateway - Common Setup
# =============================================================================
# Common setup for all istio steps.
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

# Istio defaults
ISTIO_VERSION="${ISTIO_VERSION:-1.22.0}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_PROFILE="${ISTIO_PROFILE:-default}"
ISTIO_INGRESS_ENABLED="${ISTIO_INGRESS_ENABLED:-false}"

# Envoy Gateway defaults
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-1.1.0}"
ENVOY_GATEWAY_NAMESPACE="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
ENVOY_GATEWAY_REPLICAS="${ENVOY_GATEWAY_REPLICAS:-2}"
ENVOY_GATEWAY_LB_IP="${ENVOY_GATEWAY_LB_IP:-192.168.123.200}"

# Kiali
KIALA_ENABLED="${KIALA_ENABLED:-false}"

# Kubeconfig
DEFAULT_KUBECONFIG="$PROJECT_ROOT/talos-cluster/kubeconfig"

# Export common variables
export STEP_DIR
export PROJECT_ROOT
export ISTIO_VERSION
export ISTIO_NAMESPACE
export ISTIO_PROFILE
export ISTIO_INGRESS_ENABLED
export ENVOY_GATEWAY_VERSION
export ENVOY_GATEWAY_NAMESPACE
export ENVOY_GATEWAY_REPLICAS
export ENVOY_GATEWAY_LB_IP
export KIALA_ENABLED
export DEFAULT_KUBECONFIG
