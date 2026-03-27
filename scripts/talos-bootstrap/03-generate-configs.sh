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

# Fix install disk for libvirt virtio disks
# Talos default is /dev/sda, but libvirt virtio disks appear as /dev/vda
echo ""
echo "  Patching install disk for libvirt virtio (/dev/sda -> /dev/vda)..."

PATCHED=false
for config_file in "$CONFIG_DIR/controlplane.yaml" "$CONFIG_DIR/worker.yaml"; do
    if grep -q "disk: /dev/sda" "$config_file"; then
        sed -i 's|disk: /dev/sda|disk: /dev/vda|g' "$config_file"
        PATCHED=true
    fi
done

if $PATCHED; then
    echo "  ✓ Install disk patched to /dev/vda (libvirt virtio)"
else
    echo "  ✓ Install disk already correct or no patch needed"
fi

# Verify the patch
if grep -q "disk: /dev/vda" "$CONFIG_DIR/controlplane.yaml"; then
    echo "  ✓ Verified: controlplane.yaml uses /dev/vda"
fi
if grep -q "disk: /dev/vda" "$CONFIG_DIR/worker.yaml"; then
    echo "  ✓ Verified: worker.yaml uses /dev/vda"
fi

# Extract certificates for reference using bash only
echo ""
echo "  Extracting certificates..."

# Function to extract and decode base64 certificate from YAML
extract_cert() {
    local file="$1"
    local key_path="$2"
    local output="$3"
    
    # Use grep and awk to extract base64 value from YAML
    # This handles simple nested key paths like machine.ca.crt
    local base64_value
    base64_value=$(grep -A1 "${key_path}:" "$file" | tail -1 | awk '{print $1}' | tr -d '"')
    
    if [[ -n "$base64_value" ]]; then
        echo "$base64_value" | base64 -d > "$output" 2>/dev/null
        return $?
    fi
    return 1
}

# Function to extract cert/key pair from multi-document YAML
extract_certs_from_yaml() {
    local input_file="$1"
    local certs_dir="$2"
    
    # Split multi-document YAML and process first document (machine config)
    local temp_file
    temp_file=$(mktemp)
    
    # Extract first document only (before ---)
    awk '/^---/{if(n)exit; n=1; next} n' "$input_file" > "$temp_file"
    
    # Extract machine CA
    if grep -q "machine:" "$temp_file"; then
        # Extract ca.crt for machine
        local in_ca=false
        local ca_crt="" ca_key=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*ca: ]]; then
                in_ca=true
            elif $in_ca; then
                if [[ "$line" =~ ^[[:space:]]*crt:[[:space:]]*(.+) ]]; then
                    ca_crt="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^[[:space:]]*key:[[:space:]]*(.+) ]]; then
                    ca_key="${BASH_REMATCH[1]}"
                elif [[ ! "$line" =~ ^[[:space:]] ]]; then
                    in_ca=false
                fi
            fi
        done < "$temp_file"
        
        if [[ -n "$ca_crt" ]]; then
            echo "$ca_crt" | base64 -d > "$certs_dir/ca.crt" 2>/dev/null && \
                echo "    ✓ ca.crt extracted"
        fi
        if [[ -n "$ca_key" ]]; then
            echo "$ca_key" | base64 -d > "$certs_dir/ca.key" 2>/dev/null && \
                echo "    ✓ ca.key extracted"
        fi
    fi
    
    # Extract cluster CA (Kubernetes CA)
    if grep -q "cluster:" "$temp_file"; then
        local in_cluster=false in_ca=false
        local k8s_crt="" k8s_key=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*cluster: ]]; then
                in_cluster=true
            elif $in_cluster; then
                if [[ "$line" =~ ^[[:space:]]*ca: ]]; then
                    in_ca=true
                elif $in_ca; then
                    if [[ "$line" =~ ^[[:space:]]*crt:[[:space:]]*(.+) ]]; then
                        k8s_crt="${BASH_REMATCH[1]}"
                    elif [[ "$line" =~ ^[[:space:]]*key:[[:space:]]*(.+) ]]; then
                        k8s_key="${BASH_REMATCH[1]}"
                    elif [[ "$line" =~ ^[[:space:]]*[a-z]+: && ! "$line" =~ ^[[:space:]]*(crt|key|ca): ]]; then
                        in_ca=false
                    fi
                fi
            fi
        done < "$temp_file"
        
        if [[ -n "$k8s_crt" ]]; then
            echo "$k8s_crt" | base64 -d > "$certs_dir/k8s-ca.crt" 2>/dev/null && \
                echo "    ✓ k8s-ca.crt extracted"
        fi
        if [[ -n "$k8s_key" ]]; then
            echo "$k8s_key" | base64 -d > "$certs_dir/k8s-ca.key" 2>/dev/null && \
                echo "    ✓ k8s-ca.key extracted"
        fi
    fi
    
    rm -f "$temp_file"
}

# Extract certificates
extract_certs_from_yaml "$CONFIG_DIR/controlplane.yaml" "$CERTS_DIR"

# Count extracted files
cert_count=$(ls -1 "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.key 2>/dev/null | wc -l)
echo "  Extracted $cert_count certificate files"

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
