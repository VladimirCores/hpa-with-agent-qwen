#!/bin/bash
# =============================================================================
# Step 03: Generate Machine Configurations
# =============================================================================
# Generates controlplane and worker machine configurations using the secrets.
# Uses explicit --talos-version v1.12 as specified.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[3/9] Generating machine configurations..."

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERTS_DIR"

# Verify secrets file exists
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "  ERROR: Secrets file not found: $SECRETS_FILE"
    echo "  Run step 02 first: ./scripts/talos-bootstrap/02-generate-secrets.sh"
    exit 1
fi

# Clean old configs (but preserve secrets)
rm -f "$CONFIG_DIR/controlplane.yaml" "$CONFIG_DIR/worker.yaml"
rm -f "$CONFIG_DIR/talosconfig" "$CONFIG_DIR/kubeconfig"
rm -f "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.key 2>/dev/null || true

# Generate configurations
ENDPOINT="https://$MASTER_IP:6443"
echo "  Cluster: $CLUSTER_NAME"
echo "  Endpoint: $ENDPOINT"
echo "  Talos Version: $TALOS_VERSION"
echo ""
echo "  Generating configs..."

if talosctl gen config "$CLUSTER_NAME" "$ENDPOINT" \
    --output-dir "$CONFIG_DIR" \
    --with-secrets "$SECRETS_FILE" \
    --talos-version "$TALOS_VERSION"; then
    echo "  ✓ Configurations generated"
else
    echo "  ERROR: Failed to generate configurations"
    exit 1
fi

# Verify generated files
if [[ ! -f "$CONFIG_DIR/controlplane.yaml" ]] || [[ ! -f "$CONFIG_DIR/worker.yaml" ]]; then
    echo "  ERROR: Configuration files not generated"
    exit 1
fi

echo ""
echo "  Generated files:"
echo "    - controlplane.yaml"
echo "    - worker.yaml"
echo "    - talosconfig"

# Extract certificates for reference
echo ""
echo "  Extracting certificates..."

python3 << 'PYTHON_EXTRACT'
import yaml
import base64
import os

config_dir = os.environ.get('CONFIG_DIR', 'talos-cluster')
certs_dir = os.environ.get('CERTS_DIR', 'talos-cluster/certs')

os.makedirs(certs_dir, exist_ok=True)

try:
    # Read controlplane.yaml (first document)
    with open(f"{config_dir}/controlplane.yaml", 'r') as f:
        docs = list(yaml.safe_load_all(f))
        config = docs[0]

    # Extract machine CA
    ca_crt = config['machine']['ca']['crt']
    ca_key = config['machine']['ca']['key']
    with open(f"{certs_dir}/ca.crt", 'w') as f:
        f.write(base64.b64decode(ca_crt).decode('utf-8'))
    with open(f"{certs_dir}/ca.key", 'w') as f:
        f.write(base64.b64decode(ca_key).decode('utf-8'))

    # Extract Kubernetes CA
    k8s_ca_crt = config['cluster']['ca']['crt']
    k8s_ca_key = config['cluster']['ca']['key']
    with open(f"{certs_dir}/k8s-ca.crt", 'w') as f:
        f.write(base64.b64decode(k8s_ca_crt).decode('utf-8'))
    with open(f"{certs_dir}/k8s-ca.key", 'w') as f:
        f.write(base64.b64decode(k8s_ca_key).decode('utf-8'))

    # Extract aggregatorCA cert (front-proxy)
    agg_crt = config['cluster']['aggregatorCA']['crt']
    agg_key = config['cluster']['aggregatorCA']['key']
    with open(f"{certs_dir}/aggregator-ca.crt", 'w') as f:
        f.write(base64.b64decode(agg_crt).decode('utf-8'))
    with open(f"{certs_dir}/aggregator-ca.key", 'w') as f:
        f.write(base64.b64decode(agg_key).decode('utf-8'))

    # Extract etcd CA cert
    etcd_crt = config['cluster']['etcd']['ca']['crt']
    etcd_key = config['cluster']['etcd']['ca']['key']
    with open(f"{certs_dir}/etcd-ca.crt", 'w') as f:
        f.write(base64.b64decode(etcd_crt).decode('utf-8'))
    with open(f"{certs_dir}/etcd-ca.key", 'w') as f:
        f.write(base64.b64decode(etcd_key).decode('utf-8'))

    # Extract service account key
    sa_key = config['cluster']['serviceAccount']['key']
    with open(f"{certs_dir}/sa.key", 'w') as f:
        f.write(base64.b64decode(sa_key).decode('utf-8'))

    # Count and report
    cert_files = [f for f in os.listdir(certs_dir) if f.endswith('.crt') or f.endswith('.key')]
    print(f"  Extracted {len(cert_files)} certificate files")
except Exception as e:
    print(f"  WARNING: Could not extract certificates: {e}")
PYTHON_EXTRACT

echo ""
echo "  Certificate files:"
echo "    - certs/ca.crt, ca.key (Talos machine CA)"
echo "    - certs/k8s-ca.crt, k8s-ca.key (Kubernetes CA)"
echo "    - certs/aggregator-ca.crt, aggregator-ca.key (front-proxy)"
echo "    - certs/etcd-ca.crt, etcd-ca.key (etcd CA)"
echo "    - certs/sa.key (service account)"

echo ""
echo "  ✓ Machine configurations ready"
echo ""
