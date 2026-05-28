#!/bin/bash
# =============================================================================
# Istio + Kiali Installation
# =============================================================================
# Installs Istio and optionally Kiali service mesh visualization.
# Currently supports Kiali installation when KIALA_ENABLED=true.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

KIALA_ENABLED="${KIALA_ENABLED:-false}"

echo "=== Istio with Envoy Gateway Installation ==="
echo ""

# Check prerequisites
echo "Checking prerequisites..."
echo ""

if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found. Please install kubectl first."
    exit 1
fi

# Check if cluster is accessible
if ! kubectl get nodes &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster."
    echo "  Make sure your cluster is running and kubeconfig is set."
    exit 1
fi

echo "Kubernetes nodes:"
kubectl get nodes
echo ""

echo "Current namespaces:"
kubectl get namespaces 2>/dev/null | head -10 || true
echo ""

# Check for Istio
if kubectl get namespace istio-system &>/dev/null; then
    echo "Istio installation detected:"
    kubectl get pods -n istio-system 2>/dev/null || echo "  (no pods found)"
else
    echo "Istio: Not installed"
    echo "  To install Istio, follow: docs/04-Istio-Envoy-Gateway-Preview.md"
fi
echo ""

# =============================================================================
# Install Kiali Service Mesh Visualization
# =============================================================================
if [[ "$KIALA_ENABLED" == "true" ]]; then
    echo "=== Installing Kiali ==="
    echo ""

    # Kiali requires Istio
    if ! kubectl get namespace istio-system &>/dev/null; then
        echo "  ⚠ Istio is not installed. Kiali requires Istio."
        echo "    Install Istio first, then run this script again with KIALA_ENABLED=true."
        echo ""
    else
        # Check if Kiali is already installed
        if kubectl get deployment kiali -n istio-system &>/dev/null; then
            echo "  ✓ Kiali already installed"
        else
            # Check for helm
            if ! command -v helm &>/dev/null; then
                echo "  ERROR: helm not found. Install helm to enable Kiali installation."
                echo "    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
                exit 1
            fi

            echo "  Adding Kiali Helm repository..."
            helm repo add kiali https://kiali.org/helm-charts 2>/dev/null || true
            helm repo update

            echo "  Installing Kiali (anonymous auth)..."
            helm upgrade --install kiali kiali/kiali-server \
                --namespace istio-system \
                --set auth.strategy="anonymous" \
                --wait \
                --timeout 180s

            echo "  ✓ Kiali installed"
        fi

        # Show access info
        echo ""
        echo "  Kiali access:"
        echo "    Port-forward: kubectl port-forward -n istio-system svc/kiali 20001:20001"
        echo "    URL: http://localhost:20001"
        echo ""

        # Check Kiali pods
        KIALI_PODS=$(kubectl get pods -n istio-system -l app=kiali --no-headers 2>/dev/null | wc -l)
        if (( KIALI_PODS > 0 )); then
            echo "  Kiali pods:"
            kubectl get pods -n istio-system -l app=kiali
        fi
    fi
    echo ""
fi

echo "=== Complete ==="
echo ""
echo "Quick reference:"
echo "  Hubble UI:    kubectl port-forward -n kube-system svc/hubble-ui 8080:80"
echo "  Kiali:        kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "  Grafana:      kubectl port-forward -n istio-system svc/grafana 3000:3000"
echo ""
