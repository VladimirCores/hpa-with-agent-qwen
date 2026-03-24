#!/bin/bash
# =============================================================================
# Step 08: Configure kubectl Access
# =============================================================================
# Fetches kubeconfig from the cluster and configures kubectl access.
# Optionally merges with local kubeconfig.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[8/9] Configuring kubectl access..."

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    echo "  WARNING: kubectl not installed"
    echo "  Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    KUBECTL_AVAILABLE=false
else
    KUBECTL_AVAILABLE=true
fi

# Wait for Kubernetes API server to be ready
echo "  Waiting for Kubernetes API..."
MAX_WAIT=180
WAITED=0
while ! kubectl --insecure-skip-tls-verify --server="https://$MASTER_IP:6443" cluster-info &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "  WARNING: Kubernetes API not ready after ${MAX_WAIT}s"
        echo "    (Bootstrap may not have completed)"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
done

# Fetch kubeconfig
KUBECONFIG_FILE="$CONFIG_DIR/kubeconfig"
echo ""
echo "  Fetching kubeconfig..."

if talosctl kubeconfig "$KUBECONFIG_FILE" --nodes "$MASTER_IP" --force --insecure 2>/dev/null; then
    echo "  ✓ kubeconfig fetched: $KUBECONFIG_FILE"
else
    echo "  WARNING: Could not fetch kubeconfig"
    if [[ -f "$KUBECONFIG_FILE" ]]; then
        echo "  Using existing kubeconfig"
    else
        echo "  Use: kubectl --insecure-skip-tls-verify --server=https://$MASTER_IP:6443"
    fi
fi

# Merge with local kubeconfig if requested
if [[ "$MERGE_KUBECONFIG" != "false" ]] && [[ -f "$KUBECONFIG_FILE" ]] && [[ -n "$HOME" ]]; then
    LOCAL_KUBECONFIG="$HOME/.kube/config"
    
    if [[ -d "$HOME/.kube" ]] && [[ -f "$LOCAL_KUBECONFIG" ]]; then
        echo ""
        echo "  Merging with local kubeconfig..."
        
        # Use KUBECONFIG environment variable to merge
        export KUBECONFIG="$LOCAL_KUBECONFIG:$KUBECONFIG_FILE"
        kubectl config view --flatten > "${LOCAL_KUBECONFIG}.merged"
        mv "${LOCAL_KUBECONFIG}.merged" "$LOCAL_KUBECONFIG"
        chmod 600 "$LOCAL_KUBECONFIG"
        
        echo "  ✓ Merged with $LOCAL_KUBECONFIG"
    fi
fi

# Set KUBECONFIG environment for current session
export KUBECONFIG="$KUBECONFIG_FILE"
echo ""
echo "  KUBECONFIG set to: $KUBECONFIG_FILE"

echo ""
echo "  ✓ kubectl configured"
echo ""
