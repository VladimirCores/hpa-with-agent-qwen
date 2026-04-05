#!/bin/bash
# =============================================================================
# Step 01: Authenticate Sudo
# =============================================================================
# Authenticates sudo and caches credentials for the script duration.
# If SUDO_PASSWORD is set in .env, uses it for non-interactive authentication.
# Otherwise, prompts for sudo password normally.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Source sudo helper
source "$STEP_DIR/00-sudo-helper.sh"

SUDO_CACHE_FILE="$PROJECT_ROOT/.sudo_cache_$(whoami)"
SUDO_CACHE_DURATION=900  # 15 minutes in seconds

# Cleanup function
cleanup() {
    rm -f "$SUDO_CACHE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "[1/11] Sudo authentication..."

# Check if session mode (no sudo required)
if [[ "$LIBVIRT_URI" == "qemu:///session" ]]; then
    echo "  Session mode detected - skipping sudo authentication"
    echo "  ✓ Running as user session"

    # Fix .vagrant directory permissions (no sudo needed)
    echo "  Fixing .vagrant permissions..."
    chown -R "$(whoami)":"$(whoami)" "$(pwd)/.vagrant" 2>/dev/null || true
    echo ""
    exit 0
fi

# System mode - authenticate sudo
if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    echo "  Using SUDO_PASSWORD from .env (non-interactive)..."
    if authenticate_sudo; then
        echo "  ✓ Sudo authenticated with password from .env"
        touch "$SUDO_CACHE_FILE"
    else
        echo "  ERROR: SUDO_PASSWORD authentication failed"
        echo "  Please check the password in .env or leave SUDO_PASSWORD empty to use interactive sudo"
        exit 1
    fi
else
    echo "  Sudo authentication required (cached during script run)..."
    sudo -v
    touch "$SUDO_CACHE_FILE"
    echo "  ✓ Sudo authenticated"
fi

# Fix .vagrant directory permissions BEFORE vagrant commands
echo "  Fixing .vagrant permissions..."
run_sudo chown -R "$(whoami)":"$(whoami)" "$(pwd)/.vagrant" 2>/dev/null || true
echo ""

exit 0
