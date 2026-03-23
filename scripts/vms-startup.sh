#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
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

# Execute steps 01-07 synchronously
for step_file in "$STEPS_DIR"/0[1-7]-*.sh; do
    if [[ -f "$step_file" ]]; then
        source "$step_file"
    fi
done

# Step 08: Run asynchronously (waiting for Talos boot)
echo "Starting step 08 (wait for Talos boot) in background..."
bash "$STEPS_DIR/08-wait-for-talos.sh" &
STEP08_PID=$!

# Wait for step 08 to complete
echo "Waiting for Talos boot to complete (PID: $STEP08_PID)..."
wait $STEP08_PID
STEP08_EXIT=$?

if [[ $STEP08_EXIT -ne 0 ]]; then
    echo "WARNING: Step 08 completed with exit code $STEP08_EXIT"
fi

# Continue with steps 09-11 synchronously
for step_file in "$STEPS_DIR"/[0-9][0-9]-*.sh; do
    if [[ -f "$step_file" ]]; then
        step_num=$(basename "$step_file" | cut -d'-' -f1)
        if [[ "$step_num" -gt 8 ]]; then
            source "$step_file"
        fi
    fi
done
