#!/bin/bash
# Poll VMs every 3 seconds and show status updates
set -euo pipefail

# Source .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_ROOT/.env" 2>/dev/null || true
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# VMs to poll
VMS=("$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2")

echo -e "${BLUE}Polling VMs every 3 seconds (Ctrl+C to stop)${NC}"
echo ""

while true; do
    echo -e "┌──────────────────────────────────────────────────────┐"
    echo -e "│ $(date '+%H:%M:%S') - VM Status                                    │"
    echo -e "├──────────────────────────────────────────────────────┤"
    
    for vm in "${VMS[@]}"; do
        # Get actual VM name (may have vagrant prefix)
        actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "$vm" | awk '{print $2}' | head -1)
        
        if [[ -n "$actual_vm" ]]; then
            state=$(virsh -c "$LIBVIRT_URI" domstate "$actual_vm" 2>/dev/null || echo "unknown")
            if [[ "$state" == "running" ]]; then
                echo -e "│ ${GREEN}✓${NC} $vm: ${GREEN}RUNNING${NC} (${actual_vm})"
            elif [[ "$state" == "shut off" ]]; then
                echo -e "│ ${RED}✗${NC} $vm: ${RED}SHUT OFF${NC}"
            else
                echo -e "│ ${YELLOW}⏳${NC} $vm: ${YELLOW}${state}${NC}"
            fi
        else
            echo -e "│ ${RED}✗${NC} $vm: ${RED}NOT FOUND${NC}"
        fi
    done
    
    echo -e "└──────────────────────────────────────────────────────┘"
    echo ""
    sleep 3
done
