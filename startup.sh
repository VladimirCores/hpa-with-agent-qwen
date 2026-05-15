#!/bin/bash
# =============================================================================
# Unified Talos Cluster Startup Script
# =============================================================================
# This script orchestrates the entire cluster lifecycle:
# 1. Local Registry setup & population
# 2. VM Provisioning (vms-startup.sh)
# 3. Talos Bootstrap (talos-bootstrap.sh)
# 4. K8s Components (k8s-components.sh)
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source .env file if it exists
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo -e "${YELLOW}WARNING: .env file not found in $PROJECT_ROOT. Using defaults.${NC}"
fi

# Parse arguments
SKIP_REGISTRY=false
SKIP_VMS=false
SKIP_BOOTSTRAP=false
SKIP_COMPONENTS=false
FORCE_RESET=false

usage() {
    echo "Usage: $0 [options]"
    echo "  --skip-registry    Skip local registry setup and population"
    echo "  --skip-vms         Skip VM provisioning"
    echo "  --skip-bootstrap   Skip Talos cluster bootstrap"
    echo "  --skip-components  Skip K8s components installation (CNI, etc.)"
    echo "  -f, --force-reset  Force reset (destroy VMs and disks, fresh start)"
    echo "  -h, --help         Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-registry)   SKIP_REGISTRY=true; shift ;;
        --skip-vms)        SKIP_VMS=true; shift ;;
        --skip-bootstrap)  SKIP_BOOTSTRAP=true; shift ;;
        --skip-components) SKIP_COMPONENTS=true; shift ;;
        -f|--force-reset)  FORCE_RESET=true; shift ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1"; usage ;;
    esac
done

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# Phase 1: Local Registry
# =============================================================================
if [[ "$SKIP_REGISTRY" != "true" ]]; then
    print_header "Phase 1: Local Registry Setup"

    echo "Starting local registry..."
    "$PROJECT_ROOT/scripts/start-local-registry.sh"

    echo "Populating local registry with images..."
    "$PROJECT_ROOT/scripts/populate-local-registry.sh"

    echo -e "${GREEN}✓ Local registry ready${NC}"
else
    echo -e "${YELLOW}Phase 1: Skipping Local Registry Setup${NC}"
fi

# =============================================================================
# Phase 2: VM Provisioning
# =============================================================================
if [[ "$SKIP_VMS" != "true" ]]; then
    print_header "Phase 2: VM Provisioning"

    VMS_ARGS=""
    [[ "$FORCE_RESET" == "true" ]] && VMS_ARGS="-f"

    if ! "$PROJECT_ROOT/scripts/vms-startup.sh" $VMS_ARGS; then
        echo -e "${RED}ERROR: VM provisioning failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ VMs are up and running${NC}"
else
    echo -e "${YELLOW}Phase 2: Skipping VM Provisioning${NC}"
fi

# =============================================================================
# Phase 3: Talos Bootstrap
# =============================================================================
if [[ "$SKIP_BOOTSTRAP" != "true" ]]; then
    print_header "Phase 3: Talos Cluster Bootstrap"

    if ! "$PROJECT_ROOT/scripts/talos-bootstrap.sh"; then
        echo -e "${RED}ERROR: Talos bootstrap failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Talos cluster bootstrapped${NC}"
else
    echo -e "${YELLOW}Phase 3: Skipping Talos Bootstrap${NC}"
fi

# =============================================================================
# Phase 4: K8s Components
# =============================================================================
if [[ "$SKIP_COMPONENTS" != "true" ]]; then
    print_header "Phase 4: Kubernetes Components (CNI, Metrics, MetalLB)"

    # Default to Cilium, Metrics Server, and MetalLB as they are standard for this project
    if ! "$PROJECT_ROOT/scripts/k8s-components.sh" --cni-cilium --with-metrics --with-metallb; then
        echo -e "${RED}ERROR: K8s components installation failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Kubernetes components installed${NC}"
else
    echo -e "${YELLOW}Phase 4: Skipping Kubernetes Components${NC}"
fi

print_header "All Systems Operational"

echo -e "${GREEN}Cluster is fully initialized and ready for use!${NC}"
echo ""
echo "Summary:"
echo "  - Local Registry:  Running"
echo "  - VMs:             Running"
echo "  - Talos/K8s:       Bootstrapped"
echo "  - CNI:             Cilium"
echo "  - LoadBalancer:    MetalLB"
echo "  - Metrics:         metrics-server"
echo ""
echo "Verification:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""
