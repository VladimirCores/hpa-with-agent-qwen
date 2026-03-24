#!/bin/bash
# Common setup for all vms-startup steps
# Sources .env file and sets up common variables

# Get script directory and project root
# STEP_DIR is the directory of the current step script
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT is two levels up: scripts/vms-startup -> scripts -> project root
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

# Set LIBVIRT_URI if not set
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

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
export STORAGE_POOL
export POOL_PATH
