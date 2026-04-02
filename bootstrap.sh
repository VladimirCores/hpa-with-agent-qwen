#!/bin/bash
# =============================================================================
# Talos Cluster Bootstrap Script
# =============================================================================
# Bootstraps Talos cluster and Kubernetes control plane
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source .env file
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo -e "${RED}ERROR: .env file not found${NC}"
    exit 1
fi

# Parse arguments
CUSTOM_CLUSTER_NAME=""
NO_MERGE_KUBECONFIG=false

while getopts "n:-:" opt; do
    case $opt in
        n) CUSTOM_CLUSTER_NAME="$OPTARG" ;;
        -)
            case "${OPTARG}" in
                no-merge) NO_MERGE_KUBECONFIG=true ;;
                *) echo "Unknown option: --${OPTARG}"; exit 1 ;;
            esac
            ;;
        *) echo "Usage: $0 [-n cluster-name] [--no-merge]"
           echo "  -n  Custom cluster name"
           echo "  --no-merge  Don't merge kubeconfig"
           exit 1 ;;
    esac
done

# Use custom cluster name if provided
if [[ -n "$CUSTOM_CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$CUSTOM_CLUSTER_NAME"
fi

export CLUSTER_NAME

# =============================================================================
# Main Script
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_header "Talos Cluster Bootstrap"

echo "Cluster Name: $CLUSTER_NAME"
echo "Master: $MASTER_IP"
echo "Workers: $WORKER_COUNT nodes"
echo "Talos Version: ${BOX_VERSION:-v1.12}"
echo ""

# Run bootstrap script
if bash "$SCRIPT_DIR/scripts/talos-bootstrap.sh" "$@"; then
    echo ""
    print_header "Bootstrap Complete"
    
    echo -e "${GREEN}Talos cluster bootstrapped successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Install Cilium CNI:"
    echo "     ./scripts/k8s-components.sh"
    echo ""
    echo "  2. Verify cluster:"
    echo "     kubectl --kubeconfig talos-cluster/kubeconfig get nodes"
    echo ""
    echo "  3. (Optional) Install metrics-server for HPA:"
    echo "     ./scripts/k8s-components.sh -m"
    echo ""
else
    echo ""
    echo -e "${RED}Bootstrap failed${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check VMs are running: virsh -c qemu:///session list"
    echo "  2. Check Talos accessible: talosctl version --nodes $MASTER_IP --insecure"
    echo "  3. Review logs in talos-cluster/"
    echo ""
    exit 1
fi

exit 0
