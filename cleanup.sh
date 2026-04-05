#!/bin/bash
# =============================================================================
# Talos Cluster Cleanup Script (Entry Point)
# =============================================================================
# This is a thin wrapper that delegates to scripts/vms-cleanup.sh
# All arguments are passed through to the real script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delegate to the real cleanup script
if [[ -x "$SCRIPT_DIR/scripts/vms-cleanup.sh" ]]; then
    exec "$SCRIPT_DIR/scripts/vms-cleanup.sh" "$@"
else
    echo "ERROR: scripts/vms-cleanup.sh not found or not executable" >&2
    exit 1
fi
