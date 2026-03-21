#!/bin/bash
# =============================================================================
# Talos Cluster Bootstrap
# =============================================================================
# This script generates machine configurations and bootstraps the Talos cluster.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Parse arguments
MERGE_KUBECONFIG=true
CUSTOM_CLUSTER_NAME=""
while getopts "n:-:" opt; do
    case $opt in
        n) CUSTOM_CLUSTER_NAME="$OPTARG" ;;
        -)
            case "${OPTARG}" in
                no-merge) MERGE_KUBECONFIG=false ;;
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-n cluster-name] [--no-merge]"; exit 1 ;;
    esac
done

# Use custom cluster name if provided
if [[ -n "$CUSTOM_CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$CUSTOM_CLUSTER_NAME"
fi

echo "=== Talos Cluster Bootstrap ==="
echo "Cluster Name: $CLUSTER_NAME"
echo "Master: $MASTER_IP"
echo "Workers: $WORKER_COUNT nodes"
echo ""

# =============================================================================
# Step 1: Check prerequisites
# =============================================================================
echo "[1/7] Checking prerequisites..."

# Check talosctl
if ! command -v talosctl &>/dev/null; then
    echo "ERROR: talosctl not found"
    echo "  Install: curl -L -o talosctl https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-amd64"
    echo "           chmod +x talosctl && sudo mv talosctl /usr/local/bin/"
    exit 1
fi
echo "  ✓ talosctl: $(talosctl version --short 2>/dev/null || echo 'installed')"

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo "WARNING: kubectl not found"
    echo "  Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    KUBECTL_AVAILABLE=false
else
    echo "  ✓ kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
    KUBECTL_AVAILABLE=true
fi

# Check VMs are running
echo "  Checking VMs..."
VM_COUNT=0
for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    if virsh -c "$LIBVIRT_URI" dominfo "$vm_name" &>/dev/null; then
        STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$vm_name" | grep "State:" | awk '{print $2}')
        if [[ "$STATE" == "running" ]]; then
            echo "    ✓ $vm_name: running"
            VM_COUNT=$((VM_COUNT + 1))
        else
            echo "    ✗ $vm_name: $STATE (not running)"
        fi
    else
        echo "    ✗ $vm_name: not found"
    fi
done

if (( VM_COUNT != 1 + WORKER_COUNT )); then
    echo "ERROR: Not all VMs are running. Expected $((1 + WORKER_COUNT)), got $VM_COUNT"
    echo "  Start VMs with: ./scripts/vms-startup.sh"
    exit 1
fi
echo ""

# =============================================================================
# Step 2: Generate machine configurations
# =============================================================================
echo "[2/7] Generating machine configurations..."

CONFIG_DIR="$PROJECT_ROOT/_cluster-configs"
mkdir -p "$CONFIG_DIR"

# Clean old configs
rm -f "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/talosconfig

# Generate configurations
echo "  Generating configs for cluster: $CLUSTER_NAME"
echo "  Endpoint: https://$MASTER_IP:6443"

talosctl gen config "$CLUSTER_NAME" "https://$MASTER_IP:6443" \
    --output-dir "$CONFIG_DIR" \
    --install-image "factory.talos.dev/installer-ce9c9525789482bb6e077f1357da789e476925723eede6227c02e0b5d6f044b9" \
    2>/dev/null || {
    # Fallback without install image (uses default)
    talosctl gen config "$CLUSTER_NAME" "https://$MASTER_IP:6443" \
        --output-dir "$CONFIG_DIR"
}

if [[ -f "$CONFIG_DIR/controlplane.yaml" ]] && [[ -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ✓ Configurations generated"
    echo "    - controlplane.yaml"
    echo "    - worker.yaml"
    echo "    - talosconfig"
else
    echo "ERROR: Failed to generate configurations"
    exit 1
fi
echo ""

# =============================================================================
# Step 3: Wait for nodes to be ready
# =============================================================================
echo "[3/7] Waiting for nodes to be ready..."

# Wait for master
echo "  Waiting for master ($MASTER_IP)..."
MAX_WAIT=120
WAITED=0
while ! talosctl --nodes "$MASTER_IP" --talosconfig "$CONFIG_DIR/talosconfig" get version &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "ERROR: Master not responding after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
done
echo "  ✓ Master ready (${WAITED}s)"

# Wait for workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    echo "  Waiting for worker $i ($WORKER_IP)..."
    WAITED=0
    while ! talosctl --nodes "$WORKER_IP" --talosconfig "$CONFIG_DIR/talosconfig" get version &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "ERROR: Worker $i not responding after ${MAX_WAIT}s"
            exit 1
        fi
        sleep 2
        WAITED=$((WAITED + 2))
        echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
    done
    echo "  ✓ Worker $i ready (${WAITED}s)"
done
echo ""

# =============================================================================
# Step 4: Apply configurations
# =============================================================================
echo "[4/7] Applying configurations..."

# Apply to master
echo "  Applying controlplane config to $MASTER_NAME ($MASTER_IP)..."
talosctl apply-config --nodes "$MASTER_IP" \
    --talosconfig "$CONFIG_DIR/talosconfig" \
    --file "$CONFIG_DIR/controlplane.yaml"
echo "  ✓ Controlplane config applied"

# Apply to workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    talosctl apply-config --nodes "$WORKER_IP" \
        --talosconfig "$CONFIG_DIR/talosconfig" \
        --file "$CONFIG_DIR/worker.yaml"
    echo "  ✓ Worker config applied to $WORKER_NAME"
done
echo ""

# =============================================================================
# Step 5: Bootstrap Kubernetes
# =============================================================================
echo "[5/7] Bootstrapping Kubernetes..."

echo "  Bootstrapping cluster..."
talosctl bootstrap --nodes "$MASTER_IP" \
    --talosconfig "$CONFIG_DIR/talosconfig"

echo "  ✓ Kubernetes bootstrapped"
echo ""

# =============================================================================
# Step 6: Configure kubectl access
# =============================================================================
echo "[6/7] Configuring kubectl access..."

if [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    if [[ "$MERGE_KUBECONFIG" == "true" ]]; then
        echo "  Merging kubeconfig..."
        talosctl kubeconfig --merge \
            --nodes "$MASTER_IP" \
            --talosconfig "$CONFIG_DIR/talosconfig" \
            --force
        echo "  ✓ kubeconfig merged"
    else
        echo "  Generating local kubeconfig..."
        talosctl kubeconfig "$CONFIG_DIR" \
            --nodes "$MASTER_IP" \
            --talosconfig "$CONFIG_DIR/talosconfig" \
            --force
        echo "  ✓ kubeconfig generated: $CONFIG_DIR/kubeconfig"
    fi

    # Wait for API server
    echo "  Waiting for Kubernetes API..."
    MAX_WAIT=60
    WAITED=0
    while ! kubectl cluster-info &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "WARNING: Kubernetes API not ready after ${MAX_WAIT}s"
            break
        fi
        sleep 2
        WAITED=$((WAITED + 2))
        echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
    done
else
    echo "  Skipping kubectl configuration (kubectl not installed)"
fi
echo ""

# =============================================================================
# Step 7: Verify cluster
# =============================================================================
echo "[7/7] Verifying cluster..."

# Check Talos members
echo "  Talos members:"
talosctl get members --nodes "$MASTER_IP" \
    --talosconfig "$CONFIG_DIR/talosconfig" 2>/dev/null | head -10 || echo "    (unable to get members)"

# Check Kubernetes nodes
if [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    echo ""
    echo "  Kubernetes nodes:"
    kubectl get nodes 2>/dev/null || echo "    (waiting for nodes to register...)"

    echo ""
    echo "  System pods:"
    kubectl get pods -A 2>/dev/null | head -15 || echo "    (waiting for pods...)"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "=== Bootstrap Summary ==="
echo "Cluster: $CLUSTER_NAME"
echo "Endpoint: https://$MASTER_IP:6443"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes"
echo ""
echo "Configuration files: $CONFIG_DIR/"
echo "  - controlplane.yaml"
echo "  - worker.yaml"
echo "  - talosconfig"
if [[ "$MERGE_KUBECONFIG" == "true" ]] && [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    echo "  - kubeconfig (merged)"
fi
echo ""
echo "Next steps:"
echo "  1. Install Kubernetes components:"
echo "     ./scripts/k8s-components.sh"
echo "  2. Verify cluster:"
echo "     kubectl get nodes"
echo "     kubectl get pods -A"
echo ""
echo "=== Bootstrap Complete ==="
