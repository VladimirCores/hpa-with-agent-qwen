#!/bin/bash
# =============================================================================
# Step 02: Generate Secrets Bundle
# =============================================================================
# Generates the Talos secrets bundle that will be used for all machine configs.
# Uses explicit --talos-version v1.12 as specified.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[2/9] Generating secrets bundle..."

mkdir -p "$CONFIG_DIR"

# Check if secrets already exist
if [[ -f "$SECRETS_FILE" ]]; then
    echo "  Secrets bundle already exists: $SECRETS_FILE"
    echo "  ✓ Using existing secrets"
    echo ""
    echo "  Note: To regenerate, remove the file first:"
    echo "    rm $SECRETS_FILE"
    echo ""
else
    # Generate secrets with explicit Talos version
    echo "  Generating secrets bundle with --talos-version $TALOS_VERSION..."
    
    if talosctl gen secrets --output-file "$SECRETS_FILE" --talos-version "$TALOS_VERSION"; then
        echo "  ✓ Secrets bundle generated: $SECRETS_FILE"
    else
        echo "  ERROR: Failed to generate secrets bundle"
        exit 1
    fi
fi

# Verify secrets file
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "  ERROR: Secrets file not found after generation"
    exit 1
fi

# Show secrets info (without exposing sensitive data)
echo ""
echo "  Secrets bundle contents:"
if grep -q "machineCa:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ machineCa (Talos machine CA)"
fi
if grep -q "kubernetesCa:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ kubernetesCa (Kubernetes CA)"
fi
if grep -q "etcdCa:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ etcdCa (etcd CA)"
fi
if grep -q "clusterCa:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ clusterCa (Cluster CA)"
fi
if grep -q "aggregatorCa:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ aggregatorCa (API aggregator CA)"
fi
if grep -q "serviceAccount:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ serviceAccount (K8s service account key)"
fi
if grep -q "secretboxEncryptionSecret:" "$SECRETS_FILE" 2>/dev/null; then
    echo "    ✓ secretboxEncryptionSecret"
fi

echo ""
echo "  ✓ Secrets bundle ready"
echo ""
