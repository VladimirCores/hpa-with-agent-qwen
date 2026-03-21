#!/bin/bash
# =============================================================================
# Install Kubernetes Components
# =============================================================================
# This script installs general Kubernetes components: CNI, metrics-server, etc.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Component versions
FLANNEL_VERSION="latest"
METRICS_SERVER_VERSION="0.7.1"

# Parse arguments
INSTALL_ALL=true
SPECIFIC_COMPONENT=""
LIST_COMPONENTS=false

while getopts "c:-:" opt; do
    case $opt in
        c) SPECIFIC_COMPONENT="$OPTARG"; INSTALL_ALL=false ;;
        -)
            case "${OPTARG}" in
                list) LIST_COMPONENTS=true; INSTALL_ALL=false ;;
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-c component] [--list]"; exit 1 ;;
    esac
done

# Available components
declare -A COMPONENTS=(
    ["flannel"]="Flannel CNI - Pod networking"
    ["metrics-server"]="Metrics Server - Resource metrics for HPA"
    ["coredns"]="CoreDNS - Cluster DNS (usually pre-installed)"
)

# Show available components
if [[ "$LIST_COMPONENTS" == "true" ]]; then
    echo "Available Kubernetes components:"
    echo ""
    for key in "${!COMPONENTS[@]}"; do
        echo "  $key - ${COMPONENTS[$key]}"
    done
    echo ""
    exit 0
fi

echo "=== Kubernetes Components Installation ==="
echo ""

# =============================================================================
# Prerequisites Check
# =============================================================================
echo "[Pre] Checking prerequisites..."

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    echo "  Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    exit 1
fi
echo "  ✓ kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    echo "  Ensure cluster is bootstrapped: ./scripts/talos-bootstrap.sh"
    exit 1
fi
echo "  ✓ Cluster: $(kubectl config current-context 2>/dev/null || echo 'connected')"

# Check nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if (( NODE_COUNT == 0 )); then
    echo "ERROR: No nodes registered in cluster"
    exit 1
fi
echo "  ✓ Nodes: $NODE_COUNT"
echo ""

# =============================================================================
# Component Installation Functions
# =============================================================================

install_flannel() {
    echo "[1/2] Installing Flannel CNI..."

    # Check if CNI already exists
    if kubectl get pods -n kube-system -l app=flannel &>/dev/null; then
        FLANNEL_PODS=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | wc -l)
        if (( FLANNEL_PODS > 0 )); then
            echo "  Flannel already installed ($FLANNEL_PODS pods)"
            echo "  ✓ Skipped"
            return 0
        fi
    fi

    # Check if any CNI is installed
    if kubectl get pods -n kube-system | grep -E "(flannel|calico|cilium|weave)" &>/dev/null; then
        echo "  Another CNI detected, skipping Flannel installation"
        echo "  ✓ Skipped"
        return 0
    fi

    # Install Flannel
    echo "  Installing Flannel $FLANNEL_VERSION..."
    kubectl apply -f "https://github.com/flannel-io/flannel/releases/${FLANNEL_VERSION}/download/kube-flannel.yml"

    # Wait for Flannel pods
    echo "  Waiting for Flannel pods..."
    kubectl wait --for=condition=ready pod -l app=flannel -n kube-system --timeout=120s 2>/dev/null || {
        echo "  WARNING: Flannel pods not ready within timeout"
    }

    echo "  ✓ Flannel installed"
}

install_metrics_server() {
    echo "[2/2] Installing metrics-server..."

    # Check if metrics-server already exists
    if kubectl get pods -n kube-system -l k8s-app=metrics-server &>/dev/null; then
        MS_PODS=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | wc -l)
        if (( MS_PODS > 0 )); then
            echo "  metrics-server already installed ($MS_PODS pods)"
            echo "  ✓ Skipped"
            return 0
        fi
    fi

    # Install metrics-server
    echo "  Installing metrics-server $METRICS_SERVER_VERSION..."
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml"

    # Patch for Talos (disable TLS verification for kubelet)
    echo "  Patching for Talos compatibility..."
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
        {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"},
        {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}
    ]' 2>/dev/null || true

    # Wait for metrics-server
    echo "  Waiting for metrics-server..."
    kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s 2>/dev/null || {
        echo "  WARNING: metrics-server not ready within timeout"
    }

    echo "  ✓ metrics-server installed"
}

# =============================================================================
# Install Components
# =============================================================================

if [[ "$INSTALL_ALL" == "true" ]]; then
    echo "Installing all components..."
    echo ""

    install_flannel
    echo ""

    install_metrics_server
    echo ""
else
    case "$SPECIFIC_COMPONENT" in
        flannel)
            install_flannel
            ;;
        metrics-server)
            install_metrics_server
            ;;
        coredns)
            echo "CoreDNS is managed by Talos and cannot be installed manually"
            echo "  Check status: kubectl get pods -n kube-system -l k8s-app=kube-dns"
            ;;
        *)
            echo "ERROR: Unknown component: $SPECIFIC_COMPONENT"
            echo "  Available: flannel, metrics-server, coredns"
            echo "  List all: $0 --list"
            exit 1
            ;;
    esac
fi

# =============================================================================
# Verification
# =============================================================================
echo "=== Verification ==="
echo ""

echo "Pods in kube-system:"
kubectl get pods -n kube-system --sort-by='.metadata.creationTimestamp'
echo ""

echo "Nodes:"
kubectl get nodes -o wide
echo ""

# Test metrics API (if metrics-server installed)
if [[ "$INSTALL_ALL" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metrics-server" ]]; then
    echo "Testing metrics API (may take a minute to populate):"
    sleep 10
    if kubectl top nodes &>/dev/null; then
        kubectl top nodes
    else
        echo "  (metrics not yet available, try again in 1-2 minutes)"
    fi
    echo ""
fi

# =============================================================================
# Summary
# =============================================================================
echo "=== Installation Summary ==="
echo ""
echo "Installed components:"
if [[ "$INSTALL_ALL" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "flannel" ]]; then
    echo "  ✓ Flannel CNI - Pod networking"
fi
if [[ "$INSTALL_ALL" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metrics-server" ]]; then
    echo "  ✓ metrics-server - Resource metrics for HPA"
fi
echo ""
echo "Next steps:"
echo "  1. Verify HPA works:"
echo "     kubectl autoscale deployment my-app --cpu-percent=50 --min=1 --max=10"
echo ""
echo "  2. Install Istio with Envoy Gateway (next step):"
echo "     ./scripts/istio-install.sh"
echo ""
echo "=== Components Installation Complete ==="
