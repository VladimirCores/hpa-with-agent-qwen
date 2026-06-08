#!/bin/bash
# =============================================================================
# Shared Logging Library
# =============================================================================
# Provides a unified log() function used by all startup scripts.
# Writes all output to both stdout (with colors) and startup.log (plain text).
# =============================================================================

# Determine project root (works when sourced from any subdirectory)
if [[ -z "${LOGGING_PROJECT_ROOT:-}" ]]; then
    LOGGING_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Log file path
STARTUP_LOG="${LOGGING_PROJECT_ROOT}/startup.log"

# Truncate log file once per top-level invocation.
# Export the guard so subprocesses (e.g. startup.sh -> vms-startup.sh) skip truncation.
if [[ -z "${_LOGGING_INITIALIZED:-}" ]]; then
    : > "$STARTUP_LOG" 2>/dev/null || true
    export _LOGGING_INITIALIZED=1
fi

# Colors (only for terminal output)
if [[ -t 1 ]]; then
    LOG_RED='\033[0;31m'
    LOG_GREEN='\033[0;32m'
    LOG_YELLOW='\033[1;33m'
    LOG_BLUE='\033[0;34m'
    LOG_NC='\033[0m'
else
    LOG_RED=''
    LOG_GREEN=''
    LOG_YELLOW=''
    LOG_BLUE=''
    LOG_NC=''
fi

# -----------------------------------------------------------------------------
# log <level> <message>
#   level: INFO, OK, WARN, ERROR, DEBUG, HEADER, STEP, or empty
#   message: the text to log
#
# Writes to both stdout (with color) and startup.log (plain text, with timestamp).
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Ensure log directory exists
    mkdir -p "$(dirname "$STARTUP_LOG")" 2>/dev/null || true

    case "$level" in
        HEADER)
            echo -e "${LOG_BLUE}═══════════════════════════════════════════════════════════${LOG_NC}"
            echo -e "${LOG_BLUE}  $message${LOG_NC}"
            echo -e "${LOG_BLUE}═══════════════════════════════════════════════════════════${LOG_NC}"
            echo ""
            {
                echo "═══════════════════════════════════════════════════════════"
                echo "  $message"
                echo "═══════════════════════════════════════════════════════════"
                echo ""
            } >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        STEP)
            echo -e "${LOG_YELLOW}▶ $message${LOG_NC}"
            echo "[$timestamp] STEP: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        OK)
            echo -e "${LOG_GREEN}✓ $message${LOG_NC}"
            echo "[$timestamp] OK: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        WARN)
            echo -e "${LOG_YELLOW}⚠ $message${LOG_NC}"
            echo "[$timestamp] WARN: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        ERROR)
            echo -e "${LOG_RED}✗ $message${LOG_NC}" >&2
            echo "[$timestamp] ERROR: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        INFO)
            echo -e "${LOG_BLUE}$message${LOG_NC}"
            echo "[$timestamp] INFO: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        DEBUG)
            echo -e "${LOG_BLUE}[DEBUG] $message${LOG_NC}"
            echo "[$timestamp] DEBUG: $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
        *)
            # Plain message (no level prefix)
            echo "$message"
            echo "[$timestamp] $message" >> "$STARTUP_LOG" 2>/dev/null || true
            ;;
    esac
}
