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
CILIUM_VERSION="1.16.0"
CALICO_VERSION="3.28.0"
METRICS_SERVER_VERSION="0.7.1"

# Parse arguments
INSTALL_ALL=true
SPECIFIC_COMPONENT=""
CNI_CHOICE="cilium"
LIST_COMPONENTS=false
INSTALL_METRICS=false

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
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-c component] [-m] [--list] [--cni-cilium] [--cni-calico] [--cni-flannel] [--with-metrics]"; exit 1 ;;
    esac
done

# Available components
declare -A COMPONENTS=(
    ["cilium"]="Cilium CNI - eBPF-based networking with L7 policies"
    ["calico"]="Calico CNI - BGP-based networking with network policies"
    ["flannel"]="Flannel CNI - Simple overlay networking"
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
    echo "Usage:"
    echo "  $0                    # Install Cilium + metrics-server (default)"
    echo "  $0 --cni-cilium       # Install Cilium only"
    echo "  $0 --cni-calico       # Install Calico only"
    echo "  $0 --cni-flannel      # Install Flannel only"
    echo "  $0 -c metrics-server  # Install metrics-server only"
    echo "  $0 --list             # Show this help"
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

install_cilium() {
    echo "[1/2] Installing Cilium CNI (latest stable)..."

    # Check if Cilium already exists
    if kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null; then
        CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
        if (( CILIUM_PODS > 0 )); then
            echo "  Cilium already installed ($CILIUM_PODS pods)"
            echo "  ✓ Skipped"
            return 0
        fi
    fi

    # Check if any CNI is installed
    if kubectl get pods -n kube-system | grep -E "(flannel|calico|weave)" &>/dev/null; then
        echo "  WARNING: Another CNI detected. Removing..."
        kubectl delete daemonset kube-flannel -n kube-system --ignore-not-found 2>/dev/null || true
        kubectl delete -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" --ignore-not-found 2>/dev/null || true
        echo "  Waiting for old CNI to be removed..."
        sleep 10
    fi

    # Check eBPF support
    echo "  Checking eBPF support..."
    KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f2)

    if (( KERNEL_MAJOR > 5 )) || (( KERNEL_MAJOR == 5 && KERNEL_MINOR >= 4 )); then
        echo "  ✓ Kernel $KERNEL_VERSION supports eBPF"
    else
        echo "  ⚠ Kernel $KERNEL_VERSION may have limited eBPF support"
    fi

    # Install Cilium CLI if not present
    if ! command -v cilium &>/dev/null; then
        echo "  Installing Cilium CLI..."
        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
        CLI_ARCH="amd64"
        if [[ "$(uname -m)" == "aarch64" ]]; then CLI_ARCH="arm64"; fi
        curl -sL --fail --remote-name-all \
            https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
        rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        echo "  ✓ Cilium CLI installed"
    fi

    # Install Cilium using cilium CLI (simpler and more reliable)
    echo "  Installing Cilium for Talos Linux with kube-proxy replacement..."
    
    # Use cilium install command with Talos-compatible settings
    cilium install \
        --set kubeProxyReplacement=true \
        --set bpf.masquerade=true \
        --set ipam.mode=kubernetes \
        --set securityContext.privileged=true \
        --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
        --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
        --set cni.chainingMode=none \
        --set cni.customConf=false \
        --set hubble.enabled=false \
        --wait --timeout 10m

    # Wait for Cilium pods to be ready
    echo "  Waiting for Cilium pods to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s 2>/dev/null || {
        echo "  WARNING: Cilium pods not ready within timeout, checking status..."
    }

    # Remove kube-proxy (Cilium replaces it)
    echo "  Removing kube-proxy (replaced by Cilium)..."
    kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found 2>/dev/null || true
    kubectl delete pod -n kube-system -l k8s-app=kube-proxy --force --grace-period=0 --ignore-not-found 2>/dev/null || true

    echo "  ✓ Cilium installed with kube-proxy replacement"
}

install_calico() {
    echo "[1/2] Installing Calico CNI $CALICO_VERSION..."

    # Check if Calico already exists
    if kubectl get pods -n calico-system -l k8s-app=calico-node &>/dev/null; then
        CALICO_PODS=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
        if (( CALICO_PODS > 0 )); then
            echo "  Calico already installed ($CALICO_PODS pods)"
            echo "  ✓ Skipped"
            return 0
        fi
    fi

    # Check if any CNI is installed
    if kubectl get pods -n kube-system | grep -E "(flannel|cilium|weave)" &>/dev/null; then
        echo "  WARNING: Another CNI detected. Removing..."
        kubectl delete -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" --ignore-not-found 2>/dev/null || true
    fi

    # Install Calico
    echo "  Installing Calico $CALICO_VERSION..."
    curl -o /tmp/calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

    # Modify CIDR if needed (match your cluster's pod CIDR)
    kubectl apply -f /tmp/calico.yaml

    # Wait for Calico pods
    echo "  Waiting for Calico pods..."
    kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s 2>/dev/null || {
        echo "  WARNING: Calico pods not ready within timeout"
    }

    rm -f /tmp/calico.yaml
    echo "  ✓ Calico installed"
}

install_flannel() {
    echo "[1/2] Installing Flannel CNI..."

    # Check if Flannel already exists
    if kubectl get pods -n kube-system -l app=flannel &>/dev/null; then
        FLANNEL_PODS=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | wc -l)
        if (( FLANNEL_PODS > 0 )); then
            echo "  Flannel already installed ($FLANNEL_PODS pods)"
            echo "  ✓ Skipped"
            return 0
        fi
    fi

    # Check if any CNI is installed
    if kubectl get pods -n kube-system | grep -E "(calico|cilium|weave)" &>/dev/null; then
        echo "  Another CNI detected, skipping Flannel installation"
        echo "  ✓ Skipped"
        return 0
    fi

    # Install Flannel
    echo "  Installing Flannel..."
    kubectl apply -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

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
    echo "Installing Cilium CNI (default)..."
    echo ""

    # Install selected CNI
    case "$CNI_CHOICE" in
        cilium)
            install_cilium
            ;;
        calico)
            install_calico
            ;;
        flannel)
            install_flannel
            ;;
    esac
    echo ""

    # Only install metrics-server if explicitly requested
    if [[ "$INSTALL_METRICS" == "true" ]]; then
        install_metrics_server
        echo ""
    fi
else
    case "$SPECIFIC_COMPONENT" in
        cilium)
            install_cilium
            ;;
        calico)
            install_calico
            ;;
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
            echo "  Available: cilium, calico, flannel, metrics-server, coredns"
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

# CNI-specific verification
echo "CNI Status:"
case "$CNI_CHOICE" in
    cilium)
        if command -v cilium &>/dev/null; then
            cilium status 2>/dev/null || echo "  (Cilium CLI not available)"
        fi
        echo ""
        echo "Hubble Status:"
        if kubectl get pods -n kube-system -l k8s-app=hubble-relay &>/dev/null; then
            kubectl get pods -n kube-system -l k8s-app=hubble-relay 2>/dev/null || echo "  (Hubble not ready)"
        else
            echo "  (Hubble not installed)"
        fi
        ;;
    calico)
        kubectl get pods -n calico-system 2>/dev/null || echo "  (Calico pods not found)"
        ;;
    flannel)
        kubectl get pods -n kube-system -l app=flannel 2>/dev/null || echo "  (Flannel pods not found)"
        ;;
esac
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
case "$CNI_CHOICE" in
    cilium)
        echo "  ✓ Cilium CNI - eBPF-based pod networking"
        echo "  ✓ kube-proxy replacement - BPF-based service routing"
        ;;
    calico)
        echo "  ✓ Calico CNI - BGP-based pod networking"
        ;;
    flannel)
        echo "  ✓ Flannel CNI - Simple overlay pod networking"
        ;;
esac
if [[ "$INSTALL_METRICS" == "true" ]] || [[ "$SPECIFIC_COMPONENT" == "metrics-server" ]]; then
    echo "  ✓ metrics-server - Resource metrics for HPA"
else
    echo "  ✗ metrics-server - Not installed (add --with-metrics or -m to install)"
fi
echo ""
echo "Next steps:"
echo "  1. Verify CNI is working:"
echo "     kubectl run test --image=nginx --restart=Never"
echo "     kubectl get pods -o wide"
echo ""
if [[ "$CNI_CHOICE" == "cilium" ]]; then
    echo "  2. Check Cilium status:"
    echo "     cilium status"
    echo ""
    echo "  3. Install metrics-server for HPA (optional):"
    echo "     $0 -m"
    echo ""
    echo "  4. Install Istio with Envoy Gateway (optional):"
    echo "     ./scripts/istio-install.sh"
    echo ""
else
    echo "  2. Install metrics-server for HPA:"
    echo "     $0 -m"
    echo ""
fi
echo "=== Components Installation Complete ==="
