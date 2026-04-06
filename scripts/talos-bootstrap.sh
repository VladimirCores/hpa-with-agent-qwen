#!/bin/bash
# =============================================================================
# Talos Cluster Bootstrap - Orchestrator
# =============================================================================
# This script orchestrates the Talos cluster bootstrap process by running
# individual step scripts in sequence.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/talos-bootstrap"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "ERROR: .env file not found in $PROJECT_ROOT" >&2
    exit 1
fi

# Set defaults for variables that may not be in .env
CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/talos-cluster}"
export CONFIG_DIR

# Parse arguments
CUSTOM_CLUSTER_NAME=""
while getopts "n:" opt; do
    case $opt in
        n) CUSTOM_CLUSTER_NAME="$OPTARG" ;;
        *) echo "Usage: $0 [-n cluster-name]"; exit 1 ;;
    esac
done

# Use custom cluster name if provided
if [[ -n "$CUSTOM_CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$CUSTOM_CLUSTER_NAME"
fi

# Export for step scripts
export CLUSTER_NAME

echo "=== Talos Cluster Bootstrap ==="
echo "Cluster Name: $CLUSTER_NAME"
echo "Master: $MASTER_IP"
echo "Workers: $WORKER_COUNT nodes"
echo "Talos Version: ${TALOS_VERSION:-v1.12}"
echo ""

# Define step functions
step_01_check_prerequisites() {
    bash "$STEPS_DIR/01-check-prerequisites.sh"
}

step_02_generate_secrets() {
    TALOS_VERSION="${TALOS_VERSION:-v1.12}" \
    bash "$STEPS_DIR/02-generate-secrets.sh"
}

step_03_generate_configs() {
    TALOS_VERSION="${TALOS_VERSION:-v1.12}" \
    bash "$STEPS_DIR/03-generate-configs.sh"
}

step_04_wait_for_nodes() {
    bash "$STEPS_DIR/04-wait-for-nodes.sh"
}

step_05_bootstrap_cluster() {
    bash "$STEPS_DIR/05-bootstrap-cluster.sh"
}

step_06_apply_configs() {
    bash "$STEPS_DIR/06-apply-configs.sh"
}

step_07_verify_bootstrap() {
    bash "$STEPS_DIR/07-verify-bootstrap.sh"
}

step_08_configure_kubectl() {
    bash "$STEPS_DIR/08-configure-kubectl.sh"
}

step_09_cluster_verify() {
    bash "$STEPS_DIR/09-cluster-verify.sh"
}

# Execute steps
echo "Executing steps..."
echo ""

# Execute a step synchronously
run_step_sync() {
    local step_name="$1"
    local step_func="$2"

    echo "Starting: $step_name"

    if $step_func; then
        echo "  ✓ Completed"
    else
        echo "  ✗ Failed"
        exit 1
    fi
    echo ""
}

# Run all steps in sequence
run_step_sync "01: Check prerequisites" "step_01_check_prerequisites"
run_step_sync "02: Generate secrets" "step_02_generate_secrets"
run_step_sync "03: Generate configs" "step_03_generate_configs"
run_step_sync "04: Wait for nodes" "step_04_wait_for_nodes"
run_step_sync "05: Bootstrap cluster" "step_05_bootstrap_cluster"
run_step_sync "06: Apply configs" "step_06_apply_configs"
run_step_sync "07: Verify bootstrap" "step_07_verify_bootstrap"
run_step_sync "08: Configure kubectl" "step_08_configure_kubectl"
run_step_sync "09: Cluster verification" "step_09_cluster_verify"

# Summary
echo "=== Bootstrap Summary ==="
echo "Cluster: $CLUSTER_NAME"
echo "Endpoint: https://$MASTER_IP:6443"
echo "Master: $MASTER_NAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT nodes"
echo ""
echo "Configuration files: $CONFIG_DIR/"
echo "  - secrets.yaml (reusable secrets bundle)"
echo "  - controlplane.yaml"
echo "  - worker.yaml"
echo "  - talosconfig"
echo "  - kubeconfig"
echo ""
echo "Next steps:"
echo "  1. Install Kubernetes components:"
echo "     ./scripts/k8s-components.sh"
echo "  2. Verify cluster:"
echo "     kubectl get nodes"
echo "     kubectl get pods -A"
echo ""
echo "=== Bootstrap Complete ==="
