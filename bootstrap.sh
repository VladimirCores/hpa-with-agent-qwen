#!/bin/bash
# =============================================================================
# Talos Cluster Bootstrap Script (Entry Point)
# =============================================================================
# This is a thin wrapper that delegates to scripts/talos-bootstrap.sh
# All arguments are passed through to the real script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delegate to the real bootstrap script
if [[ -x "$SCRIPT_DIR/scripts/talos-bootstrap.sh" ]]; then
    exec "$SCRIPT_DIR/scripts/talos-bootstrap.sh" "$@"
else
    echo "ERROR: scripts/talos-bootstrap.sh not found or not executable" >&2
    exit 1
fi
