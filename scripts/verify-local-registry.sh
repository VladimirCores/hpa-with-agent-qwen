#!/bin/bash
# =============================================================================
# Verify Local Registry Configuration and Cached Images
# =============================================================================
# This script verifies that:
# 1. Local registry is running and accessible
# 2. Required images are cached in the registry
# 3. Talos configuration includes proper registry mirror settings
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo -e "${YELLOW}WARNING: .env file not found, using defaults${NC}"
fi

NETWORK_IP="${NETWORK_IP:-192.168.123.1}"
REGISTRY_URL="${NETWORK_IP}:5000"
CONFIG_DIR="$PROJECT_ROOT/talos-cluster"

echo "============================================================================="
echo "Local Registry Verification"
echo "============================================================================="
echo ""

# =============================================================================
# Check 1: Registry Container Status
# =============================================================================
echo -e "${BLUE}[1/5] Checking local registry container status...${NC}"

if podman ps -q -f name="local-registry" | grep -q .; then
    echo -e "  ${GREEN}✓${NC} Local registry container is running"
    REGISTRY_STATUS=$(podman ps --filter name="local-registry" --format "{{.Status}}")
    echo "    Status: $REGISTRY_STATUS"
else
    if podman ps -aq -f name="local-registry" | grep -q .; then
        echo -e "  ${YELLOW}⚠${NC} Local registry container exists but is stopped"
        echo "    Start it with: podman start local-registry"
    else
        echo -e "  ${RED}✗${NC} Local registry container does not exist"
        echo "    Create it with: $SCRIPT_DIR/start-local-registry.sh"
    fi
fi
echo ""

# =============================================================================
# Check 2: Registry Accessibility
# =============================================================================
echo -e "${BLUE}[2/5] Testing registry accessibility...${NC}"

if curl -s --connect-timeout 5 "http://${REGISTRY_URL}/v2/_catalog" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Registry is accessible at http://${REGISTRY_URL}"
    
    # List repositories
    echo "    Available repositories:"
    curl -s "http://${REGISTRY_URL}/v2/_catalog" | python3 -c "import sys,json; data=json.load(sys.stdin); repos=data.get('repositories',[]); [print(f'      - {r}') for r in repos[:10]]" 2>/dev/null || true
    
    REPO_COUNT=$(curl -s "http://${REGISTRY_URL}/v2/_catalog" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null || echo "0")
    echo "    Total repositories: $REPO_COUNT"
else
    echo -e "  ${RED}✗${NC} Registry is NOT accessible at http://${REGISTRY_URL}"
    echo "    Troubleshooting:"
    echo "      - Check if registry container is running: podman ps | grep local-registry"
    echo "      - Check firewall rules: sudo firewall-cmd --list-ports"
    echo "      - Test connectivity: curl -v http://${REGISTRY_URL}/v2/_catalog"
fi
echo ""

# =============================================================================
# Check 3: Cached Images Verification
# =============================================================================
echo -e "${BLUE}[3/5] Verifying cached images...${NC}"

# Define critical images that should be present
CRITICAL_IMAGES=(
    "ghcr.io/siderolabs/installer"
    "registry.k8s.io/kube-apiserver"
    "registry.k8s.io/kube-controller-manager"
    "registry.k8s.io/kube-scheduler"
    "registry.k8s.io/kube-proxy"
    "registry.k8s.io/etcd"
    "registry.k8s.io/pause"
    "registry.k8s.io/coredns/coredns"
    "quay.io/cilium/cilium"
    "quay.io/cilium/operator-generic"
)

# Check which images are cached locally
CACHED_COUNT=0
MISSING_COUNT=0

for IMAGE_BASE in "${CRITICAL_IMAGES[@]}"; do
    # Check if any tag of this image exists in local storage
    if podman images --format "{{.Repository}}" | grep -q "^${REGISTRY_URL}/${IMAGE_BASE}$"; then
        CACHED_COUNT=$((CACHED_COUNT + 1))
    else
        MISSING_COUNT=$((MISSING_COUNT + 1))
        echo -e "  ${YELLOW}⚠${NC} Missing: $IMAGE_BASE"
    fi
done

if [[ $MISSING_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}✓${NC} All $CACHED_COUNT critical images are cached"
else
    echo -e "  ${YELLOW}⚠${NC} $MISSING_COUNT critical images missing from cache"
    echo "    Run: $SCRIPT_DIR/populate-local-registry.sh"
fi
echo ""

# =============================================================================
# Check 4: Talos Configuration Registry Mirrors
# =============================================================================
echo -e "${BLUE}[4/5] Checking Talos configuration for registry mirrors...${NC}"

if [[ -f "$CONFIG_DIR/controlplane.yaml" ]]; then
    echo "  Checking controlplane.yaml..."
    
    # Check for registry mirrors configuration
    if grep -q "registries:" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Registry configuration found"
        
        # Count configured mirrors
        MIRROR_COUNT=$(grep -c "endpoints:" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null || echo "0")
        echo "    Configured mirror endpoints: $MIRROR_COUNT"
        
        # List mirrored registries
        echo "    Mirrored registries:"
        grep -A1 "mirrors:" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null | grep -E "^\s+\"?" | head -10 | while read -r line; do
            echo "      - $(echo "$line" | sed 's/.*"\(.*\)".*/\1/' | tr -d ' :"')"
        done
        
        # Check for insecureSkipVerify
        if grep -q "insecureSkipVerify: true" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Insecure registry access configured"
        else
            echo -e "  ${YELLOW}⚠${NC} insecureSkipVerify not configured (may cause TLS issues)"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} No registry configuration found in controlplane.yaml"
        echo "    Run: scripts/talos-bootstrap/03-generate-configs.sh to regenerate configs"
    fi
    
    # Check installer image
    if grep -q "image:.*${REGISTRY_URL}" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null; then
        INSTALLER_IMAGE=$(grep "image:" "$CONFIG_DIR/controlplane.yaml" | head -1 | awk '{print $2}')
        echo -e "  ${GREEN}✓${NC} Installer image points to local registry: $INSTALLER_IMAGE"
    else
        echo -e "  ${YELLOW}⚠${NC} Installer image may not use local registry"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} Talos config not found at $CONFIG_DIR/controlplane.yaml"
    echo "    Generate configs with: scripts/talos-bootstrap/03-generate-configs.sh"
fi
echo ""

# =============================================================================
# Check 5: Podman Storage Statistics
# =============================================================================
echo -e "${BLUE}[5/5] Podman storage statistics...${NC}"

TOTAL_IMAGES=$(podman images --format "{{.Repository}}" | wc -l)
LOCAL_REGISTRY_IMAGES=$(podman images --format "{{.Repository}}" | grep -c "^${REGISTRY_URL}/" || echo "0")
TOTAL_SIZE=$(podman images --format "{{.Size}}" | awk '{sum+=$1} END {printf "%.2f", sum/1024}' 2>/dev/null || echo "0")

echo "  Total images in storage: $TOTAL_IMAGES"
echo "  Images for local registry: $LOCAL_REGISTRY_IMAGES"
echo "  Estimated total size: ${TOTAL_SIZE} MB"
echo ""

# Show largest images
echo "  Top 5 largest images:"
podman images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null | sort -t$'\t' -k2 -h | tail -5 | while IFS=$'\t' read -r repo size; do
    echo "    - $repo ($size)"
done
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "============================================================================="
echo "Verification Summary"
echo "============================================================================="

ISSUES_FOUND=0

if ! podman ps -q -f name="local-registry" | grep -q .; then
    echo -e "  ${RED}✗${NC} Local registry is not running"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if ! curl -s --connect-timeout 5 "http://${REGISTRY_URL}/v2/_catalog" >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} Registry is not accessible"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [[ $MISSING_COUNT -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠${NC} $MISSING_COUNT critical images missing from cache"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || ! grep -q "registries:" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} Talos config missing registry mirror configuration"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

echo ""

if [[ $ISSUES_FOUND -eq 0 ]]; then
    echo -e "${GREEN}✓ All checks passed! Your local registry is properly configured.${NC}"
    echo ""
    echo "Your cluster components will pull images from the local cache."
else
    echo -e "${YELLOW}⚠ Found $ISSUES_FOUND issue(s) that need attention.${NC}"
    echo ""
    echo "Recommended actions:"
    if ! podman ps -q -f name="local-registry" | grep -q .; then
        echo "  1. Start the registry: $SCRIPT_DIR/start-local-registry.sh"
    fi
    if [[ $MISSING_COUNT -gt 0 ]]; then
        echo "  2. Populate cache: $SCRIPT_DIR/populate-local-registry.sh"
    fi
    if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || ! grep -q "registries:" "$CONFIG_DIR/controlplane.yaml" 2>/dev/null; then
        echo "  3. Regenerate Talos configs: scripts/talos-bootstrap/03-generate-configs.sh"
    fi
fi

echo ""
exit $ISSUES_FOUND
