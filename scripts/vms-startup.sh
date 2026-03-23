#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# All steps run asynchronously with progress monitoring.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/vms-startup"

# Source .env file
set -a
source "$PROJECT_ROOT/.env"
set +a

# Parse arguments
SKIP_CLEANUP=false
FORCE_RESET=false
while getopts "sf" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        *) echo "Usage: $0 [-s] [-f]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
           exit 1 ;;
    esac
done

echo "=== Talos Cluster VM Startup ==="
echo ""

# Source helper functions
source "$STEPS_DIR/00-helper-functions.sh"

# Array to track background PIDs
declare -a STEP_PIDS=()

# Execute all steps asynchronously
echo "Starting all steps asynchronously..."
echo ""

for step_file in "$STEPS_DIR"/[0-9][0-9]-*.sh; do
    if [[ -f "$step_file" ]]; then
        step_name=$(basename "$step_file" | sed 's/^[0-9]*-//' | sed 's/\.sh$//')
        echo "Starting step: $step_name (PID will be assigned)..."
        bash "$step_file" &
        STEP_PIDS+=($!)
        echo "  → Started with PID ${STEP_PIDS[-1]}"
    fi
done

echo ""
echo "All steps started. Waiting for completion..."
echo ""

# Wait for all steps to complete
FAILED=0
for i in "${!STEP_PIDS[@]}"; do
    pid=${STEP_PIDS[$i]}
    if wait $pid; then
        echo "✓ Step $((i+1)) completed successfully (PID: $pid)"
    else
        echo "✗ Step $((i+1)) failed (PID: $pid)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [[ $FAILED -gt 0 ]]; then
    echo "WARNING: $FAILED step(s) completed with errors"
    exit 1
else
    echo "=== All steps completed successfully ==="
fi
