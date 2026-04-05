#!/bin/bash
# =============================================================================
# Sudo Helper Functions
# =============================================================================
# Provides run_sudo function that uses SUDO_PASSWORD from .env if set,
# otherwise falls back to normal sudo (interactive prompt).
# =============================================================================

# Run command with sudo, using SUDO_PASSWORD if available
# Usage: run_sudo <command> [args...]
# Returns: exit code of the command
run_sudo() {
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}

# Run command with sudo, suppressing password prompts
# Usage: run_sudo_quiet <command> [args...]
# Returns: exit code of the command
run_sudo_quiet() {
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
    else
        sudo "$@" 2>/dev/null
    fi
}

# Authenticate sudo non-interactively if SUDO_PASSWORD is set
# Usage: authenticate_sudo
# Returns: 0 if authenticated, 1 if failed
authenticate_sudo() {
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        if echo "$SUDO_PASSWORD" | sudo -S -v 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        # No password set, try normal sudo validation
        if sudo -n true 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}
