#!/bin/bash
# =============================================================================
# Cluster Health Monitor
# =============================================================================
# Continuous monitoring script for Talos Kubernetes cluster health.
# Checks node readiness, pod status, and LoadBalancer services.
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/../talos-cluster}"
KUBECONFIG="${KUBECONFIG:-$CONFIG_DIR/kubeconfig}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds
LOG_FILE="${LOG_FILE:-}"  # Optional log file
PID_FILE="${PID_FILE:-/tmp/cluster-health-monitor.pid}"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
    echo -e "${BLUE}${msg}${NC}"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"
    echo -e "${YELLOW}${msg}${NC}"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo -e "${RED}${msg}${NC}"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

log_ok() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] OK: $*"
    echo -e "${GREEN}${msg}${NC}"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 1
    fi

    if [[ ! -f "$KUBECONFIG" ]]; then
        log_error "Kubeconfig not found at $KUBECONFIG"
        exit 1
    fi

    export KUBECONFIG="$KUBECONFIG"
}

# Check node readiness
check_nodes() {
    local not_ready_count=0
    local total_count=0

    while IFS= read -r line; do
        total_count=$((total_count + 1))
        if [[ ! "$line" =~ "Ready" ]]; then
            not_ready_count=$((not_ready_count + 1))
            local node_name=$(echo "$line" | awk '{print $1}')
            local node_status=$(echo "$line" | awk '{print $2}')
            log_warn "Node not ready: $node_name (status: $node_status)"
        fi
    done < <(kubectl get nodes --no-headers 2>/dev/null)

    if [[ $total_count -eq 0 ]]; then
        log_error "No nodes found in cluster"
        return 1
    elif [[ $not_ready_count -gt 0 ]]; then
        log_warn "$not_ready_count/$total_count nodes not ready"
        return 1
    else
        log_ok "All $total_count nodes ready"
        return 0
    fi
}

# Check pod status
check_pods() {
    local crashing_count=0
    local error_count=0
    local pending_count=0

    while IFS= read -r line; do
        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')

        case "$status" in
            "CrashLoopBackOff")
                crashing_count=$((crashing_count + 1))
                log_warn "Pod CrashLoopBackOff: $namespace/$pod_name"
                ;;
            "Error")
                error_count=$((error_count + 1))
                log_warn "Pod Error: $namespace/$pod_name"
                ;;
            "Pending")
                pending_count=$((pending_count + 1))
                # Only warn if pending for extended period
                if [[ $pending_count -gt 5 ]]; then
                    log_warn "Pod Pending: $namespace/$pod_name (one of $pending_count pending pods)"
                fi
                ;;
        esac
    done < <(kubectl get pods -A --no-headers 2>/dev/null)

    local total_issues=$((crashing_count + error_count))

    if [[ $total_issues -gt 0 ]]; then
        log_warn "$crashing_count pods in CrashLoopBackOff, $error_count pods in Error state"
        return 1
    else
        log_ok "All pods healthy (no CrashLoopBackOff or Error states)"
        return 0
    fi
}

# Check LoadBalancer services
check_loadbalancers() {
    local pending_count=0
    local assigned_count=0

    while IFS= read -r line; do
        local namespace=$(echo "$line" | awk '{print $1}')
        local service_name=$(echo "$line" | awk '{print $2}')
        local cluster_ip=$(echo "$line" | awk '{print $3}')
        local external_ip=$(echo "$line" | awk '{print $4}')

        if [[ "$external_ip" == "<pending>" ]]; then
            pending_count=$((pending_count + 1))
            log_warn "LoadBalancer pending: $namespace/$service_name"
        else
            assigned_count=$((assigned_count + 1))
        fi
    done < <(kubectl get svc -A --no-headers 2>/dev/null | grep LoadBalancer)

    if [[ $pending_count -gt 0 ]]; then
        log_warn "$pending_count LoadBalancer services pending IP assignment"
        return 1
    else
        log_ok "All LoadBalancer services have IPs assigned ($assigned_count services)"
        return 0
    fi
}

# Check critical system pods
check_critical_pods() {
    local critical_namespaces=("kube-system" "calico-system" "metallb-system")
    local issues_found=0

    for ns in "${critical_namespaces[@]}"; do
        if ! kubectl get ns "$ns" &>/dev/null; then
            continue
        fi

        local not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        if [[ $not_ready -gt 0 ]]; then
            log_warn "Critical namespace $ns has $not_ready pods not Running/Completed"
            issues_found=1
        fi
    done

    if [[ $issues_found -eq 0 ]]; then
        log_ok "All critical system pods healthy"
    fi

    return $issues_found
}

# Main monitoring loop
monitor_loop() {
    log_info "Starting cluster health monitor (interval: ${CHECK_INTERVAL}s)"
    log_info "Using kubeconfig: $KUBECONFIG"
    [[ -n "$LOG_FILE" ]] && log_info "Logging to: $LOG_FILE"

    local iteration=0

    while true; do
        iteration=$((iteration + 1))
        echo ""
        echo "============================================================================="
        log_info "=== Health Check Iteration #$iteration ==="
        echo "============================================================================="

        local overall_status=0

        check_nodes || overall_status=1
        check_pods || overall_status=1
        check_loadbalancers || overall_status=1
        check_critical_pods || overall_status=1

        echo ""
        if [[ $overall_status -eq 0 ]]; then
            log_ok "=== All checks passed ==="
        else
            log_warn "=== Some checks failed - review warnings above ==="
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# Run in background
run_background() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_error "Monitor already running with PID $old_pid"
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    log_info "Starting health monitor in background..."
    nohup "$0" --foreground > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    log_info "Monitor started with PID $pid"
    log_info "To stop: kill $pid or run: $0 --stop"
}

# Stop background process
stop_background() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping monitor (PID $pid)..."
            kill "$pid"
            rm -f "$PID_FILE"
            log_ok "Monitor stopped"
        else
            log_warn "Monitor not running (stale PID file)"
            rm -f "$PID_FILE"
        fi
    else
        log_warn "No PID file found - monitor may not be running"
    fi
}

# Show status
show_status() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_ok "Monitor is running (PID $pid)"
            return 0
        else
            log_warn "Monitor not running (stale PID file)"
            return 1
        fi
    else
        log_info "Monitor is not running"
        return 1
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Cluster Health Monitor for Talos Kubernetes Cluster

Options:
    --foreground      Run in foreground (default)
    --background      Run in background as daemon
    --stop            Stop background monitor
    --status          Show monitor status
    --interval SECS   Set check interval (default: 60)
    --log FILE        Log output to file
    --kubeconfig FILE Path to kubeconfig (default: $KUBECONFIG)
    -h, --help        Show this help message

Examples:
    $(basename "$0")                          # Run in foreground
    $(basename "$0") --background             # Run in background
    $(basename "$0") --stop                   # Stop background monitor
    $(basename "$0") --interval 30            # Check every 30 seconds
    $(basename "$0") --log /var/log/health.log  # Log to file

EOF
}

# Parse arguments
FOREGROUND=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --foreground)
            FOREGROUND=true
            shift
            ;;
        --background)
            FOREGROUND=false
            shift
            ;;
        --stop)
            stop_background
            exit 0
            ;;
        --status)
            show_status
            exit $?
            ;;
        --interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
check_kubectl

if [[ "$FOREGROUND" == "true" ]]; then
    monitor_loop
else
    run_background
fi
