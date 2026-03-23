#!/bin/bash
# Step 01: Authenticate sudo
# Authenticates sudo and caches credentials for the script duration

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

SUDO_CACHE_FILE="$PROJECT_ROOT/.sudo_cache_$(whoami)"
SUDO_CACHE_DURATION=900  # 15 minutes in seconds

# Cleanup function
cleanup() {
    rm -f "$SUDO_CACHE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "[1/11] Authenticating sudo..."
echo "  Sudo authentication required (cached during script run)..."
sudo -v
touch "$SUDO_CACHE_FILE"
echo "  ✓ Sudo authenticated"

# Fix .vagrant directory permissions BEFORE vagrant commands
echo "  Fixing .vagrant permissions..."
sudo chown -R "$(whoami)":"$(whoami)" "$(pwd)/.vagrant" 2>/dev/null || true
echo ""
