#!/bin/bash
# =============================================================================
# Istio + Envoy Gateway Installation - Orchestrator
# =============================================================================
# Installs Istio service mesh with Envoy Gateway ingress, and optionally Kiali.
# Runs step scripts in sequence (following k8s-components.sh pattern).
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/istio"

# Source shared logging library
source "$PROJECT_ROOT/scripts/logging.sh"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Configuration from .env (with defaults)
ISTIO_VERSION="${ISTIO_VERSION:-1.22.0}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_INGRESS_ENABLED="${ISTIO_INGRESS_ENABLED:-false}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-1.1.0}"
ENVOY_GATEWAY_NAMESPACE="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
ENVOY_GATEWAY_REPLICAS="${ENVOY_GATEWAY_REPLICAS:-2}"
ENVOY_GATEWAY_LB_IP="${ENVOY_GATEWAY_LB_IP:-192.168.123.200}"
KIALA_ENABLED="${KIALA_ENABLED:-false}"

# Parse arguments
SKIP_VERIFY=false

while getopts "s-:" opt; do
    case $opt in
        s) SKIP_VERIFY=true ;;
        -)
            case "${OPTARG}" in
                skip-verify) SKIP_VERIFY=true ;;
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-s] [--skip-verify]"; exit 1 ;;
    esac
done

# =============================================================================
# Main Script
# =============================================================================
log HEADER "Istio + Envoy Gateway Installation"

log INFO "Configuration:"
log INFO "  Istio version:          $ISTIO_VERSION"
log INFO "  Istio namespace:        $ISTIO_NAMESPACE"
log INFO "  Envoy Gateway version:  $ENVOY_GATEWAY_VERSION"
log INFO "  Envoy Gateway IP:       $ENVOY_GATEWAY_LB_IP"
log INFO "  Envoy Gateway replicas: $ENVOY_GATEWAY_REPLICAS"
log INFO "  Istio ingress enabled:  $ISTIO_INGRESS_ENABLED"
log INFO "  Kiali enabled:          $KIALA_ENABLED"

# =============================================================================
# Step Functions
# =============================================================================

step_01_check_prerequisites() {
    bash "$STEPS_DIR/01-check-prerequisites.sh"
}

step_02_install_istio_base() {
    ISTIO_VERSION="$ISTIO_VERSION" \
    ISTIO_NAMESPACE="$ISTIO_NAMESPACE" \
    bash "$STEPS_DIR/02-install-istio-base.sh"
}

step_03_install_istiod() {
    ISTIO_VERSION="$ISTIO_VERSION" \
    ISTIO_NAMESPACE="$ISTIO_NAMESPACE" \
    bash "$STEPS_DIR/03-install-istiod.sh"
}

step_04_install_envoy_gateway() {
    ENVOY_GATEWAY_VERSION="$ENVOY_GATEWAY_VERSION" \
    ENVOY_GATEWAY_NAMESPACE="$ENVOY_GATEWAY_NAMESPACE" \
    ENVOY_GATEWAY_REPLICAS="$ENVOY_GATEWAY_REPLICAS" \
    ENVOY_GATEWAY_LB_IP="$ENVOY_GATEWAY_LB_IP" \
    bash "$STEPS_DIR/04-install-envoy-gateway.sh"
}

step_05_configure_integration() {
    ISTIO_NAMESPACE="$ISTIO_NAMESPACE" \
    ENVOY_GATEWAY_NAMESPACE="$ENVOY_GATEWAY_NAMESPACE" \
    ISTIO_INGRESS_ENABLED="$ISTIO_INGRESS_ENABLED" \
    bash "$STEPS_DIR/05-configure-integration.sh"
}

step_06_install_kiali() {
    ISTIO_NAMESPACE="$ISTIO_NAMESPACE" \
    KIALA_ENABLED="$KIALA_ENABLED" \
    bash "$STEPS_DIR/06-install-kiali.sh"
}

step_07_verify() {
    ISTIO_NAMESPACE="$ISTIO_NAMESPACE" \
    ENVOY_GATEWAY_NAMESPACE="$ENVOY_GATEWAY_NAMESPACE" \
    ENVOY_GATEWAY_LB_IP="$ENVOY_GATEWAY_LB_IP" \
    bash "$STEPS_DIR/07-verify.sh"
}

# =============================================================================
# Helper Function
# =============================================================================

run_step() {
    local step_name="$1"
    local step_func="$2"

    log STEP "$step_name"

    if $step_func; then
        log OK "Completed: $step_name"
    else
        log ERROR "Installation failed at: $step_name"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check the error message above"
        echo "  2. Verify cluster connectivity: kubectl get nodes"
        echo "  3. Check for already-installed components: kubectl get ns"
        echo "  4. Re-run script: $0"
        echo ""
        exit 1
    fi
}

# =============================================================================
# Execute Steps
# =============================================================================

run_step "01: Check prerequisites"                              "step_01_check_prerequisites"
run_step "02: Install Istio base (CRDs)"                        "step_02_install_istio_base"
run_step "03: Install Istiod (control plane)"                   "step_03_install_istiod"
run_step "04: Install Envoy Gateway"                            "step_04_install_envoy_gateway"
run_step "05: Configure Istio + Envoy Gateway integration"      "step_05_configure_integration"
run_step "06: Install Kiali (optional)"                         "step_06_install_kiali"

if [[ "$SKIP_VERIFY" != "true" ]]; then
    run_step "07: Verify installation"                          "step_07_verify"
else
    log STEP "07: Verify installation (skipped)"
fi

# =============================================================================
# Summary
# =============================================================================
log HEADER "Installation Complete"

log INFO "Installed components:"
log INFO "  ✓ Istio (istiod) — Service mesh control plane"
log INFO "  ✓ Envoy Gateway — Ingress gateway (Gateway API)"
if [[ "$KIALA_ENABLED" == "true" ]]; then
    log INFO "  ✓ Kiali — Service mesh visualization"
fi
log INFO ""
log INFO "Access:"
log INFO "  Envoy Gateway (via MetalLB):  http://$ENVOY_GATEWAY_LB_IP"
log INFO "  Kiali:                        kubectl port-forward -n $ISTIO_NAMESPACE svc/kiali 20001:20001"
log INFO ""
log INFO "Configuration: $PROJECT_ROOT/.env"
log INFO ""
log INFO "Next steps:"
log INFO "  1. Deploy sample application with sidecar injection:"
log INFO "     kubectl create ns sample-app"
log INFO "     kubectl label ns sample-app istio-injection=enabled"
log INFO "     kubectl -n sample-app apply -f docs/examples/sample-app.yaml"
log INFO ""
log INFO "  2. Create HTTPRoute to expose via Envoy Gateway:"
log INFO "     See docs/04-Istio-Envoy-Gateway-Integration.md"
log INFO ""
log INFO "  3. Configure HPA:"
log INFO "     kubectl -n sample-app autoscale deployment my-app --cpu-percent=50 --min=1 --max=10"

log OK "Istio + Envoy Gateway Installation Complete"
