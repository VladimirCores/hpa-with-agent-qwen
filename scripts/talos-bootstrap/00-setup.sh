#!/bin/bash
# =============================================================================
# Talos Bootstrap - Common Setup
# =============================================================================
# Common setup for all talos-bootstrap steps.
# Sources .env file and sets up common variables.
# =============================================================================

set -euo pipefail

# Get script directory and project root
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$STEP_DIR")")"

# Source .env file if not already sourced
if [[ -z "${NETWORK_NAME:-}" ]]; then
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
    else
        echo "ERROR: .env file not found in $PROJECT_ROOT" >&2
        exit 1
    fi
fi

# Set defaults
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
TALOS_VERSION="${TALOS_VERSION:-v1.13}"

# Configuration directories
CONFIG_DIR="$PROJECT_ROOT/talos-cluster"
CERTS_DIR="$CONFIG_DIR/certs"
SECRETS_FILE="$CONFIG_DIR/secrets.yaml"

# Export common variables
export STEP_DIR
export PROJECT_ROOT
export LIBVIRT_URI
export NETWORK_NAME
export MASTER_NAME
export MASTER_IP
export WORKER_COUNT
export WORKER_NAME_PREFIX
export WORKER_IP_BASE
export CLUSTER_NAME
export TALOS_VERSION
export CONFIG_DIR
export CERTS_DIR
export SECRETS_FILE

# Source shared logging library
LOGGING_SCRIPT="$PROJECT_ROOT/scripts/logging.sh"
if [[ -f "$LOGGING_SCRIPT" ]]; then
    source "$LOGGING_SCRIPT"
fi

# Set TALOSCONFIG environment variable for talosctl commands
export TALOSCONFIG="$CONFIG_DIR/talosconfig"
