#!/bin/bash
# =============================================================================
# Step 02: Install Cilium CNI
# =============================================================================
# Installs Cilium CNI with kube-proxy replacement for Talos Linux.
# Includes Hubble UI for network observability.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/5] Installing Cilium CNI $CILIUM_VERSION..."
echo ""
echo "  Configuration:"
echo "    kube-proxy replacement: enabled (always on)"
echo "    Hubble UI:              $HUBBLE_ENABLED"
echo ""

# Check if Cilium already exists
if kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null; then
    CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
    if (( CILIUM_PODS > 0 )); then
        echo "  Cilium already installed ($CILIUM_PODS pods)"
        echo "  ✓ Skipped"
        exit 0
    fi
fi

# Remove Flannel CNI if present (required before installing Cilium)
echo "  Removing Flannel CNI (if present)..."
kubectl delete daemonset kube-flannel -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" --ignore-not-found 2>/dev/null || true
kubectl delete pod -n kube-system -l app=flannel --force --grace-period=0 --ignore-not-found 2>/dev/null || true
kubectl delete ns kube-flannel --ignore-not-found 2>/dev/null || true
echo "  ✓ Flannel removed"

# Remove Calico if present
if kubectl get ns calico-system &>/dev/null; then
    echo "  Removing Calico (if present)..."
    kubectl delete -f "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete ns calico-system --ignore-not-found 2>/dev/null || true
    echo "  ✓ Calico removed"
fi

# Wait for old CNI pods to terminate
echo "  Waiting for old CNI pods to terminate..."
sleep 15

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
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    echo "  ✓ Cilium CLI installed"
fi

# Install Cilium using cilium CLI with Talos-compatible settings
echo "  Installing Cilium for Talos Linux..."

# Build Cilium install command with dynamic options
CILIUM_CMD=(
    cilium
    install
    --set "kubeProxyReplacement=true"
    --set "bpf.masquerade=true"
    --set "ipam.mode=kubernetes"
    --set "securityContext.privileged=true"
    --set "securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
    --set "securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
    --set "cni.chainingMode=none"
    --set "cni.customConf=false"
    --set "hubble.enabled=$HUBBLE_ENABLED"
)

# Add Hubble relay if enabled
if [[ "$HUBBLE_ENABLED" == "true" ]]; then
    CILIUM_CMD+=(--set "hubble.relay.enabled=$CILIUM_HUBBLE_RELAY_ENABLED")
    CILIUM_CMD+=(--set "hubble.ui.enabled=true")
fi

# Add wait flag
CILIUM_CMD+=(--wait)

# Execute the command
echo "  Running: cilium install ${CILIUM_CMD[*]:5}"
"${CILIUM_CMD[@]}"

# Wait for Cilium pods to be ready
echo "  Waiting for Cilium pods to be ready..."
sleep 10
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s 2>/dev/null || {
    echo "  WARNING: Cilium pods not ready within timeout, checking status..."
}

# Remove kube-proxy (always replaced by Cilium BPF-based routing)
echo "  Removing kube-proxy (replaced by Cilium BPF-based routing)..."
kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --force --grace-period=0 --ignore-not-found 2>/dev/null || true
echo "  ✓ kube-proxy removed"

# Enable Hubble CLI if available
if [[ "$HUBBLE_ENABLED" == "true" ]]; then
    echo ""
    echo "  Enabling Hubble..."
    
    # Enable Hubble in Cilium
    cilium hubble enable 2>/dev/null || {
        echo "  ⚠ Hubble enable via CLI failed, may already be enabled"
    }
    
    # Wait for Hubble pods
    sleep 5
    kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=hubble-relay --timeout=120s 2>/dev/null || {
        echo "  ⚠ Hubble relay not ready within timeout"
    }
    kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=hubble-ui --timeout=120s 2>/dev/null || {
        echo "  ⚠ Hubble UI not ready within timeout"
    }

    echo "  ✓ Hubble UI enabled"
    echo "    Access: kubectl port-forward -n kube-system svc/hubble-ui 8080:80"

    # Stabilize Hubble pods with automatic retry logic
    echo "  Stabilizing Hubble pods..."
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        # Check Hubble relay status
        HUBBLE_RELAY_STATUS=$(kubectl get pod -n kube-system -l k8s-app=hubble-relay --no-headers 2>/dev/null | awk '{print $3}')
        HUBBLE_UI_STATUS=$(kubectl get pod -n kube-system -l k8s-app=hubble-ui --no-headers 2>/dev/null | awk '{print $3}')

        if [[ "$HUBBLE_RELAY_STATUS" == "CrashLoopBackOff" || "$HUBBLE_UI_STATUS" == "CrashLoopBackOff" ]]; then
            echo "    ⚠ Hubble pods unstable (relay: $HUBBLE_RELAY_STATUS, ui: $HUBBLE_UI_STATUS), restarting... (attempt $((retry_count + 1))/$max_retries)"
            kubectl rollout restart deployment hubble-relay -n kube-system 2>/dev/null || true
            kubectl rollout restart deployment hubble-ui -n kube-system 2>/dev/null || true
            sleep 30
            retry_count=$((retry_count + 1))

            # Wait for pods to stabilize
            kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=hubble-relay --timeout=60s 2>/dev/null || true
            kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=hubble-ui --timeout=60s 2>/dev/null || true
        else
            echo "    ✓ Hubble pods stable"
            break
        fi
    done

    if [[ $retry_count -ge $max_retries ]]; then
        echo "  ⚠ WARNING: Hubble pods still unstable after $max_retries retries"
        echo "    Manual intervention may be required:"
        echo "      kubectl rollout restart deployment hubble-relay -n kube-system"
        echo "      kubectl rollout restart deployment hubble-ui -n kube-system"
    fi
fi

echo ""
echo "  ✓ Cilium installed with kube-proxy replacement"
if [[ "$HUBBLE_ENABLED" == "true" ]]; then
    echo "  ✓ Hubble UI enabled for network observability"
fi
echo ""
