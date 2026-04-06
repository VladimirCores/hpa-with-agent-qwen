#!/bin/bash
# =============================================================================
# Install Kubernetes Components - Orchestrator
# =============================================================================
# This script orchestrates the installation of Kubernetes components by running
# individual step scripts in sequence (following talos-bootstrap.sh pattern).
#
# Available Components:
#   - CNI: Cilium (default), Calico, or Flannel
#   - Metrics Server: Resource metrics for HPA
#   - MetalLB: LoadBalancer Services for bare-metal clusters
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/k8s-components"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Use versions from .env if available, otherwise use defaults
CILIUM_VERSION="${CILIUM_VERSION:-1.19.1}"
CALICO_VERSION="${CALICO_VERSION:-3.28.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-0.7.1}"

# MetalLB configuration
METALLB_VERSION="${METALLB_VERSION:-0.14.8}"
METALLB_IP_POOL_START="${METALLB_IP_POOL_START:-192.168.123.200}"
METALLB_IP_POOL_END="${METALLB_IP_POOL_END:-192.168.123.250}"
METALLB_MODE="${METALLB_MODE:-l2}"
ENVOY_GATEWAY_LB_IP="${ENVOY_GATEWAY_LB_IP:-}"

# Parse arguments
INSTALL_ALL=true
SPECIFIC_COMPONENT=""
CNI_CHOICE="cilium"
LIST_COMPONENTS=false
INSTALL_METRICS=false
INSTALL_METALLB=false

while getopts "c:m-:" opt; do
    case $opt in
        c) SPECIFIC_COMPONENT="$OPTARG"; INSTALL_ALL=false ;;
        m) INSTALL_METRICS=true; INSTALL_ALL=false ;;
        -)
            case "${OPTARG}" in
                list) LIST_COMPONENTS=true; INSTALL_ALL=false ;;
                cni-cilium) CNI_CHOICE="cilium"; INSTALL_ALL=false ;;
                cni-calico) CNI_CHOICE="calico"; INSTALL_ALL=false ;;
                cni-flannel) CNI_CHOICE="flannel"; INSTALL_ALL=false ;;
                with-metrics) INSTALL_METRICS=true ;;
                with-metallb) INSTALL_METALLB=true ;;
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-c component] [-m] [--list] [--cni-cilium] [--cni-calico] [--cni-flannel] [--with-metrics] [--with-metallb]"; exit 1 ;;
    esac
done

# Show available components
if [[ "$LIST_COMPONENTS" == "true" ]]; then
    echo "Available Kubernetes components:"
    echo ""
    echo "  CNI Providers:"
    echo "    cilium          - Cilium CNI - eBPF-based networking with L7 policies (default)"
    echo "    calico          - Calico CNI - BGP-based networking with network policies"
    echo "    flannel         - Flannel CNI - Simple overlay networking"
    echo ""
    echo "  Add-on Components:"
    echo "    metrics-server  - Metrics Server - Resource metrics for HPA"
    echo "    metallb         - MetalLB LoadBalancer - External IP for Services"
    echo ""
    echo "Usage:"
    echo "  $0                           # Install Cilium only (default)"
    echo "  $0 --cni-cilium              # Install Cilium only"
    echo "  $0 --cni-calico              # Install Calico only"
    echo "  $0 --cni-flannel             # Install Flannel only"
    echo "  $0 --with-metrics            # Install CNI + metrics-server"
    echo "  $0 --with-metallb            # Install CNI + MetalLB"
    echo "  $0 --with-metrics --with-metallb  # Install all components"
    echo "  $0 -c metrics-server         # Install metrics-server only"
    echo "  $0 -c metallb                # Install MetalLB only"
    echo "  $0 --list                    # Show this help"
    echo ""
    echo "Configuration (.env):"
    echo "  CILIUM_VERSION=$CILIUM_VERSION"
    echo "  METALLB_IP_POOL_START=$METALLB_IP_POOL_START"
    echo "  METALLB_IP_POOL_END=$METALLB_IP_POOL_END"
    echo "  METALLB_MODE=$METALLB_MODE"
    echo ""
    exit 0
fi

# =============================================================================
# Main Script
# =============================================================================
echo "=== Kubernetes Components Installation ==="
echo ""
echo "Configuration:"
echo "  CNI:            $CNI_CHOICE"
echo "  Metrics Server: $INSTALL_METRICS"
echo "  MetalLB:        $INSTALL_METALLB"
if [[ "$INSTALL_METALLB" == "true" ]]; then
    echo "  IP Pool:        $METALLB_IP_POOL_START-$METALLB_IP_POOL_END"
    echo "  Mode:           $METALLB_MODE"
    if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
        echo "  Envoy GW IP:    $ENVOY_GATEWAY_LB_IP"
    fi
fi
echo ""

# =============================================================================
# Step Functions
# =============================================================================

step_01_check_prerequisites() {
    bash "$STEPS_DIR/01-check-prerequisites.sh"
}

step_02_install_cni() {
    case "$CNI_CHOICE" in
        cilium)
            CILIUM_VERSION="$CILIUM_VERSION" \
            CILIUM_KUBE_PROXY_REPLACEMENT="$CILIUM_KUBE_PROXY_REPLACEMENT" \
            CILIUM_HUBBLE_ENABLED="$CILIUM_HUBBLE_ENABLED" \
            CILIUM_HUBBLE_RELAY_ENABLED="$CILIUM_HUBBLE_RELAY_ENABLED" \
            bash "$STEPS_DIR/02-install-cilium.sh"
            ;;
        calico)
            CALICO_VERSION="$CALICO_VERSION" bash "$STEPS_DIR/02-install-calico.sh"
            ;;
        flannel)
            bash "$STEPS_DIR/02-install-flannel.sh"
            ;;
    esac
}

step_03_install_metrics() {
    METRICS_SERVER_VERSION="$METRICS_SERVER_VERSION" bash "$STEPS_DIR/03-install-metrics-server.sh"
}

step_04_install_metallb() {
    METALLB_VERSION="$METALLB_VERSION" \
    METALLB_IP_POOL_START="$METALLB_IP_POOL_START" \
    METALLB_IP_POOL_END="$METALLB_IP_POOL_END" \
    METALLB_MODE="$METALLB_MODE" \
    ENVOY_GATEWAY_LB_IP="$ENVOY_GATEWAY_LB_IP" \
    EXPOSE_HUBBLE_UI="$EXPOSE_HUBBLE_UI" \
    HUBBLE_UI_LB_IP="$HUBBLE_UI_LB_IP" \
    EXPOSE_K8S_DASHBOARD="$EXPOSE_K8S_DASHBOARD" \
    K8S_DASHBOARD_LB_IP="$K8S_DASHBOARD_LB_IP" \
    bash "$STEPS_DIR/04-install-metallb.sh"
}

step_05_verify() {
    bash "$STEPS_DIR/05-verify-installation.sh" "$CNI_CHOICE" "$INSTALL_METRICS" "$INSTALL_METALLB"
}

# =============================================================================
# Helper Function
# =============================================================================

run_step_sync() {
    local step_name="$1"
    local step_func="$2"

    echo "Starting: $step_name"

    if $step_func; then
        echo "  ✓ Completed"
    else
        echo "  ✗ Failed"
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Installation failed at: $step_name"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check the error message above"
        echo "  2. Verify cluster connectivity: kubectl get nodes"
        echo "  3. Re-run script: $0"
        echo ""
        exit 1
    fi
    echo ""
}

# =============================================================================
# Execute Steps
# =============================================================================

# Step 01: Always check prerequisites
run_step_sync "01: Check prerequisites" "step_01_check_prerequisites"

# Step 02: Install CNI
if [[ "$INSTALL_ALL" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "" && "$INSTALL_METRICS" == "false" && "$INSTALL_METALLB" == "false" ]] || \
   [[ "$SPECIFIC_COMPONENT" == "cilium" || "$SPECIFIC_COMPONENT" == "calico" || "$SPECIFIC_COMPONENT" == "flannel" ]]; then
    run_step_sync "02: Install CNI ($CNI_CHOICE)" "step_02_install_cni"
fi

# Step 03: Install metrics-server (only if explicitly requested)
if [[ "$INSTALL_METRICS" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metrics-server" ]]; then
    run_step_sync "03: Install metrics-server" "step_03_install_metrics"
fi

# Step 04: Install MetalLB (only if explicitly requested)
if [[ "$INSTALL_METALLB" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metallb" ]]; then
    run_step_sync "04: Install MetalLB" "step_04_install_metallb"
fi

# Step 05: Verify installation (if anything was installed)
if [[ "$INSTALL_ALL" == "true" ]] || [[ "$SPECIFIC_COMPONENT" != "" ]] || [[ "$INSTALL_METRICS" == "true" ]] || [[ "$INSTALL_METALLB" == "true" ]]; then
    run_step_sync "05: Verify installation" "step_05_verify"
fi

# =============================================================================
# Summary
# =============================================================================
echo "=== Installation Summary ==="
echo ""
echo "Installed components:"
echo "  ✓ $CNI_CHOICE CNI"
if [[ "$INSTALL_METRICS" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metrics-server" ]]; then
    echo "  ✓ metrics-server"
fi
if [[ "$INSTALL_METALLB" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metallb" ]]; then
    echo "  ✓ MetalLB LoadBalancer"
    if [[ -n "$ENVOY_GATEWAY_LB_IP" ]]; then
        echo "  ✓ Envoy Gateway dedicated IP: $ENVOY_GATEWAY_LB_IP"
    fi
fi
echo ""
echo "Configuration files: $PROJECT_ROOT/.env"
echo ""
echo "Next steps:"
echo "  1. Verify cluster:"
echo "     kubectl get nodes"
echo "     kubectl get pods -A"
echo ""
if [[ "$INSTALL_METALLB" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metallb" ]]; then
    echo "  2. Test LoadBalancer Service:"
    echo "     See: docs/09-MetalLB-LoadBalancer.md"
    echo ""
    echo "  3. Install Istio with Envoy Gateway:"
    echo "     ./scripts/istio-install.sh"
    echo ""
fi
echo "=== Components Installation Complete ==="

