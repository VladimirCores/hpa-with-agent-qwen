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

# Configuration directory (separate from generated configs)
CONFIG_DIR="$PROJECT_ROOT/talos-cluster"
CERTS_DIR="$CONFIG_DIR/certs"

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
EXPECTED_VMS=$((1 + WORKER_COUNT))

# Get actual VM names from virsh (handles Vagrant prefix)
# Match VMs ending with the expected names
MASTER_VM=""
WORKER_VMS=()

# Find master VM (matches talos-master or prefix_talos-master)
while IFS= read -r line; do
    VM_NAME=$(echo "$line" | awk '{print $2}')
    if [[ "$VM_NAME" == *"$MASTER_NAME" ]]; then
        MASTER_VM="$VM_NAME"
        break
    fi
done < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -v "^ Id")

# Find worker VMs
for i in $(seq 1 $WORKER_COUNT); do
    while IFS= read -r line; do
        VM_NAME=$(echo "$line" | awk '{print $2}')
        if [[ "$VM_NAME" == *"${WORKER_NAME_PREFIX}${i}" ]]; then
            WORKER_VMS+=("$VM_NAME")
            break
        fi
    done < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -v "^ Id")
done

# Check master
if [[ -n "$MASTER_VM" ]]; then
    STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$MASTER_VM" 2>/dev/null | grep "State:" | awk '{print $2}')
    if [[ "$STATE" == "running" ]]; then
        echo "    ✓ $MASTER_VM: running"
        VM_COUNT=$((VM_COUNT + 1))
    else
        echo "    ✗ $MASTER_VM: $STATE (not running)"
    fi
else
    echo "    ✗ $MASTER_NAME: not found"
fi

# Check workers
for WORKER_VM in "${WORKER_VMS[@]}"; do
    STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$WORKER_VM" 2>/dev/null | grep "State:" | awk '{print $2}')
    if [[ "$STATE" == "running" ]]; then
        echo "    ✓ $WORKER_VM: running"
        VM_COUNT=$((VM_COUNT + 1))
    else
        echo "    ✗ $WORKER_VM: $STATE (not running)"
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

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERTS_DIR"

# Clean old configs
rm -f "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/talosconfig "$CONFIG_DIR"/kubeconfig
rm -f "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.key

# Generate configurations
echo "  Generating configs for cluster: $CLUSTER_NAME"
echo "  Endpoint: https://$MASTER_IP:6443"

# Use system installer (matches running Talos version)
# Generate with correct endpoint from the start
talosctl gen config "$CLUSTER_NAME" "https://$MASTER_IP:6443" \
    --output-dir "$CONFIG_DIR"

if [[ -f "$CONFIG_DIR/controlplane.yaml" ]] && [[ -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ✓ Configurations generated"
    echo "    - controlplane.yaml"
    echo "    - worker.yaml"
    echo "    - talosconfig"

    # Extract certificates for reference (don't modify talosconfig)
    echo "  Extracting certificates..."

    # Use Python to parse YAML and extract certs (handles multi-document YAML)
    CONFIG_DIR="$CONFIG_DIR" CERTS_DIR="$CERTS_DIR" python3 << 'PYTHON_EXTRACT'
import yaml
import base64
import os
import sys

config_dir = os.environ.get('CONFIG_DIR', 'talos-cluster')
certs_dir = os.environ.get('CERTS_DIR', 'talos-cluster/certs')

# Read controlplane.yaml (first document)
with open(f"{config_dir}/controlplane.yaml", 'r') as f:
    # Get first document only (machine config)
    docs = list(yaml.safe_load_all(f))
    config = docs[0]

# Extract machine CA (used by Talos)
ca_crt = config['machine']['ca']['crt']
ca_key = config['machine']['ca']['key']
with open(f"{certs_dir}/ca.crt", 'w') as f:
    f.write(base64.b64decode(ca_crt).decode('utf-8'))
with open(f"{certs_dir}/ca.key", 'w') as f:
    f.write(base64.b64decode(ca_key).decode('utf-8'))

# Extract Kubernetes CA (used by K8s components)
k8s_ca_crt = config['cluster']['ca']['crt']
k8s_ca_key = config['cluster']['ca']['key']
with open(f"{certs_dir}/k8s-ca.crt", 'w') as f:
    f.write(base64.b64decode(k8s_ca_crt).decode('utf-8'))
with open(f"{certs_dir}/k8s-ca.key", 'w') as f:
    f.write(base64.b64decode(k8s_ca_key).decode('utf-8'))

# Extract aggregatorCA cert (front-proxy)
agg_crt = config['cluster']['aggregatorCA']['crt']
agg_key = config['cluster']['aggregatorCA']['key']
with open(f"{certs_dir}/aggregator-ca.crt", 'w') as f:
    f.write(base64.b64decode(agg_crt).decode('utf-8'))
with open(f"{certs_dir}/aggregator-ca.key", 'w') as f:
    f.write(base64.b64decode(agg_key).decode('utf-8'))

# Extract etcd CA cert
etcd_crt = config['cluster']['etcd']['ca']['crt']
etcd_key = config['cluster']['etcd']['ca']['key']
with open(f"{certs_dir}/etcd-ca.crt", 'w') as f:
    f.write(base64.b64decode(etcd_crt).decode('utf-8'))
with open(f"{certs_dir}/etcd-ca.key", 'w') as f:
    f.write(base64.b64decode(etcd_key).decode('utf-8'))

# Extract service account key
sa_key = config['cluster']['serviceAccount']['key']
with open(f"{certs_dir}/sa.key", 'w') as f:
    f.write(base64.b64decode(sa_key).decode('utf-8'))

print(f"  Extracted {len(os.listdir(certs_dir))} certificate files")
PYTHON_EXTRACT

    echo "  ✓ Certificates extracted"
    echo "    - certs/ca.crt, ca.key (Talos machine CA)"
    echo "    - certs/k8s-ca.crt, k8s-ca.key (Kubernetes CA)"
    echo "    - certs/aggregator-ca.crt, aggregator-ca.key"
    echo "    - certs/etcd-ca.crt, etcd-ca.key"
    echo "    - certs/sa.key"
else
    echo "ERROR: Failed to generate configurations"
    exit 1
fi
echo ""

# =============================================================================
# Step 3: Wait for nodes to be ready
# =============================================================================
echo "[3/7] Waiting for nodes to be ready..."

# Wait for master (use --insecure for pre-bootstrap connection)
echo "  Waiting for master ($MASTER_IP)..."
MAX_WAIT=120
WAITED=0
while ! talosctl --endpoints "$MASTER_IP" --nodes "$MASTER_IP" get version --insecure &>/dev/null; do
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
    while ! talosctl --endpoints "$WORKER_IP" --nodes "$WORKER_IP" get version --insecure &>/dev/null; do
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
# Step 4: Bootstrap FIRST, then apply config
# =============================================================================
echo "[4/7] Bootstrapping cluster (before apply-config)..."

# CRITICAL: Bootstrap MUST happen BEFORE apply-config
# After apply-config, node reboots with new certs and we can't authenticate
# Bootstrap while node is still in maintenance mode

echo "  Bootstrapping cluster..."
# Bootstrap in maintenance mode - no talosconfig needed
# Note: Talos v1.11.x bootstrap doesn't support --insecure flag
# It connects without auth when node is in maintenance mode
if talosctl bootstrap --nodes "$MASTER_IP" --endpoints "$MASTER_IP"; then
    echo "  ✓ Kubernetes bootstrapped"
else
    echo "  ERROR: Bootstrap failed"
    echo "  Make sure Talos is running and accessible"
    exit 1
fi

# Now apply config (node will reboot but certs are already valid)
echo "  Applying controlplane config to $MASTER_NAME ($MASTER_IP)..."
talosctl apply-config --endpoints "$MASTER_IP" --nodes "$MASTER_IP" \
    --file "$CONFIG_DIR/controlplane.yaml" \
    --insecure
echo "  ✓ Controlplane config applied"

# Apply to workers
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_IP=$(echo "$WORKER_IP_BASE" | awk -F. -v n="$((i-1))" '{print $1"."$2"."$3"."$4+n}')
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    echo "  Applying worker config to $WORKER_NAME ($WORKER_IP)..."
    talosctl apply-config --endpoints "$WORKER_IP" --nodes "$WORKER_IP" \
        --file "$CONFIG_DIR/worker.yaml" \
        --insecure
    echo "  ✓ Worker config applied to $WORKER_NAME"
done
echo ""

# =============================================================================
# Step 5: Wait for nodes to reboot and verify
# =============================================================================
echo "[5/7] Waiting for master to reboot..."

MAX_WAIT=120
WAITED=0
while ! talosctl --endpoints "$MASTER_IP" --nodes "$MASTER_IP" get version --insecure &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "ERROR: Master not ready after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
done
echo "  ✓ Master rebooted (${WAITED}s)"

# Verify bootstrap worked
echo "  Verifying bootstrap..."
sleep 5
if talosctl --endpoints "$MASTER_IP" --nodes "$MASTER_IP" get members --insecure &>/dev/null; then
    talosctl --endpoints "$MASTER_IP" --nodes "$MASTER_IP" get members --insecure 2>/dev/null | head -10
    echo "  ✓ Bootstrap verified"

    # Change boot order to disk
    echo "  Setting VM boot order to disk..."
    if [[ -x "$SCRIPT_DIR/set-boot-order.sh" ]]; then
        "$SCRIPT_DIR/set-boot-order.sh" 2>/dev/null || echo "    WARNING: Could not change boot order"
    fi
else
    echo "  WARNING: Unable to verify bootstrap"
fi
echo ""

# =============================================================================
# Step 6: Configure kubectl access
# =============================================================================
echo "[6/7] Configuring kubectl access..."

if [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    # Wait for Kubernetes API server to be ready
    echo "  Waiting for Kubernetes API..."
    MAX_WAIT=180
    WAITED=0
    while ! kubectl --insecure-skip-tls-verify --server="https://$MASTER_IP:6443" cluster-info &>/dev/null; do
        if (( WAITED >= MAX_WAIT )); then
            echo "WARNING: Kubernetes API not ready after ${MAX_WAIT}s"
            echo "  (Bootstrap may not have completed)"
            break
        fi
        sleep 2
        WAITED=$((WAITED + 2))
        echo "    ... waiting ($WAITED/${MAX_WAIT}s)"
    done

    # Try to get kubeconfig (requires successful bootstrap)
    if talosctl kubeconfig "$CONFIG_DIR/kubeconfig" \
        --endpoints "$MASTER_IP" --nodes "$MASTER_IP" \
        --force 2>/dev/null; then
        echo "  ✓ kubeconfig fetched"
        export KUBECONFIG="$CONFIG_DIR/kubeconfig"
    elif [[ -f "$CONFIG_DIR/kubeconfig" ]]; then
        echo "  Using existing kubeconfig..."
        export KUBECONFIG="$CONFIG_DIR/kubeconfig"
    else
        echo "  WARNING: Could not fetch kubeconfig"
        echo "  Use: kubectl --insecure-skip-tls-verify --server=https://$MASTER_IP:6443"
    fi
else
    echo "  Skipping kubectl configuration (kubectl not installed)"
fi
echo ""

# =============================================================================
# Step 7: Verify cluster
# =============================================================================
echo "[7/7] Verifying cluster..."

# Check Kubernetes nodes
if [[ "$KUBECTL_AVAILABLE" == "true" ]]; then
    echo "  Kubernetes nodes:"
    kubectl get nodes 2>/dev/null || echo "    (waiting for nodes to register...)"

    echo ""
    echo "  System pods:"
    kubectl get pods -A 2>/dev/null | head -15 || echo "    (waiting for pods...)"

    echo ""
    echo "  Cluster info:"
    kubectl cluster-info 2>/dev/null | head -3 || echo "    (unable to get cluster info)"
else
    echo "  kubectl not available, skipping Kubernetes verification"
fi

echo ""

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
