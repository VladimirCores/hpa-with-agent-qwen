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

# Source shared logging library
source "$PROJECT_ROOT/scripts/logging.sh"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    log ERROR ".env file not found in $PROJECT_ROOT"
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

log HEADER "Talos Cluster Bootstrap"
log INFO "Cluster Name: $CLUSTER_NAME"
log INFO "Master: $MASTER_IP"
log INFO "Workers: $WORKER_COUNT nodes"
log INFO "Talos Version: ${TALOS_VERSION:-v1.12}"

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

step_09_install_dashboard() {
    bash "$STEPS_DIR/09-install-dashboard.sh"
}

step_10_cluster_verify() {
    bash "$STEPS_DIR/09-cluster-verify.sh"
}

# Execute steps
log INFO "Executing steps..."

# Execute a step synchronously
run_step_sync() {
    local step_name="$1"
    local step_func="$2"

    log STEP "$step_name"

    if $step_func; then
        log OK "Completed"
    else
        log ERROR "Failed"
        exit 1
    fi
}

# Run all steps in sequence
run_step_sync "01: Check prerequisites" "step_01_check_prerequisites"
run_step_sync "02: Generate secrets" "step_02_generate_secrets"
run_step_sync "03: Generate configs" "step_03_generate_configs"
run_step_sync "04: Wait for nodes" "step_04_wait_for_nodes"
run_step_sync "05: Bootstrap cluster (apply config + bootstrap + workers)" "step_05_bootstrap_cluster"
run_step_sync "06: Apply worker configs (standalone fallback)" "step_06_apply_configs"
run_step_sync "07: Verify bootstrap" "step_07_verify_bootstrap"
run_step_sync "08: Configure kubectl" "step_08_configure_kubectl"
run_step_sync "09: Install Kubernetes Dashboard" "step_09_install_dashboard"
run_step_sync "10: Cluster verification" "step_10_cluster_verify"

# Summary
log HEADER "Bootstrap Summary"
log INFO "Cluster: $CLUSTER_NAME"
log INFO "Endpoint: https://$MASTER_IP:6443"
log INFO "Master: $MASTER_NAME ($MASTER_IP)"
log INFO "Workers: $WORKER_COUNT nodes"
log INFO ""
log INFO "Configuration files: $CONFIG_DIR/"
log INFO "  - secrets.yaml (reusable secrets bundle)"
log INFO "  - controlplane.yaml"
log INFO "  - worker.yaml"
log INFO "  - talosconfig"
log INFO "  - kubeconfig"
log INFO ""
log INFO "Next steps:"
log INFO "  1. Access Kubernetes Dashboard:"
log INFO "     kubectl --kubeconfig $CONFIG_DIR/kubeconfig -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443"
log INFO "     Open: https://localhost:8443"
log INFO "     Token: $CONFIG_DIR/dashboard-admin-token.txt"
log INFO ""
log INFO "  2. Install Kubernetes components:"
log INFO "     ./scripts/k8s-components.sh"
log INFO "  3. Verify cluster:"
log INFO "     kubectl get nodes"
log INFO "     kubectl get pods -A"

log OK "Bootstrap Complete"
