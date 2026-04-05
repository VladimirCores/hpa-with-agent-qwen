#!/bin/bash
# =============================================================================
# Talos Cluster Startup Script (Entry Point)
# =============================================================================
# This is a thin wrapper that delegates to scripts/vms-startup.sh
# All arguments are passed through to the real script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delegate to the real startup script
if [[ -x "$SCRIPT_DIR/scripts/vms-startup.sh" ]]; then
    exec "$SCRIPT_DIR/scripts/vms-startup.sh" "$@"
else
    echo "ERROR: scripts/vms-startup.sh not found or not executable" >&2
    exit 1
fi
