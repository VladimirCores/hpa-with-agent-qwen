#!/bin/bash
# =============================================================================
# Infisical Secret Manager Installation
# =============================================================================
# Installs Infisical - an open source secret manager with dashboard for Kubernetes.
# https://github.com/Infisical/infisical
# =============================================================================

set -euo pipefail

# Infisical versions
INFISICAL_VERSION="0.60.0"
POSTGRES_VERSION="15.5.0"

echo "=== Infisical Secret Manager Installation ==="
echo ""
echo "Infisical is an open source secret manager with:"
echo "  ✓ Modern web dashboard"
echo "  ✓ Secret versioning and audit logs"
echo "  ✓ Kubernetes operator integration"
echo "  ✓ RBAC and access controls"
echo "  ✓ Self-hosted (fully open source, MIT license)"
echo ""

# =============================================================================
# Prerequisites Check
# =============================================================================
echo "[Pre] Checking prerequisites..."

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    echo "  Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    exit 1
fi
echo "  ✓ kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"

# Check Helm
if ! command -v helm &>/dev/null; then
    echo "ERROR: Helm not found"
    echo "  Install: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
echo "  ✓ Helm: $(helm version --short)"

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    echo "  Ensure cluster is bootstrapped and kubeconfig is set"
    exit 1
fi
echo "  ✓ Cluster: $(kubectl config current-context 2>/dev/null || echo 'connected')"

# Check nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if (( NODE_COUNT == 0 )); then
    echo "ERROR: No nodes registered in cluster"
    exit 1
fi
echo "  ✓ Nodes: $NODE_COUNT"

# Check if Infisical already exists
if kubectl get namespace infisical &>/dev/null 2>&1; then
    echo ""
    echo "  ⚠ Infisical namespace already exists"
    read -p "  Do you want to reinstall? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "  Uninstalling existing Infisical..."
        helm uninstall infisical -n infisical 2>/dev/null || true
        kubectl delete namespace infisical --ignore-not-found 2>/dev/null || true
        sleep 5
    else
        echo "  Installation cancelled"
        exit 0
    fi
fi

echo ""

# =============================================================================
# Installation
# =============================================================================
echo "[1/5] Adding Infisical Helm repository..."
if ! helm repo add infisical https://infisical.github.io/helm-charts &>/dev/null; then
    echo "  ERROR: Failed to add Infisical Helm repository"
    exit 1
fi
helm repo update
echo "  ✓ Helm repository added and updated"

echo ""
echo "[2/5] Creating infisical namespace..."
kubectl create namespace infisical --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Namespace created"

echo ""
echo "[3/5] Installing PostgreSQL (required by Infisical)..."
helm upgrade --install infisical-postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
    --namespace infisical \
    --version $POSTGRES_VERSION \
    --set auth.username=infisical \
    --set auth.password=infisical123 \
    --set auth.database=infisical \
    --set primary.persistence.size=1Gi \
    --wait --timeout 5m

echo "  ✓ PostgreSQL installed"

echo ""
echo "[4/5] Installing Infisical..."
helm upgrade --install infisical infisical/infisical \
    --namespace infisical \
    --version $INFISICAL_VERSION \
    --set postgresql.enabled=false \
    --set postgresql.auth.username=infisical \
    --set postgresql.auth.password=infisical123 \
    --set postgresql.auth.database=infisical \
    --set postgresql.primary.service.host=infisical-postgresql \
    --set postgresql.primary.service.port=5432 \
    --set infisical.seedSecret.name=infisical-seed \
    --set ingress.enabled=false \
    --wait --timeout 10m

echo "  ✓ Infisical installed"

echo ""
echo "[5/5] Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=infisical -n infisical --timeout=300s 2>/dev/null || {
    echo "  WARNING: Some pods not ready within timeout"
}

# =============================================================================
# Verification
# =============================================================================
echo ""
echo "=== Verification ==="
echo ""

echo "Infisical pods:"
kubectl get pods -n infisical -l app.kubernetes.io/instance=infisical

echo ""
echo "Infisical services:"
kubectl get svc -n infisical -l app.kubernetes.io/instance=infisical

echo ""
echo "PostgreSQL pods:"
kubectl get pods -n infisical -l app.kubernetes.io/name=postgresql

# =============================================================================
# Access Instructions
# =============================================================================
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Access Infisical Dashboard:"
echo ""
echo "  1. Port-forward the UI service:"
echo "     kubectl port-forward svc/infisical-ui -n infisical 8081:80"
echo ""
echo "  2. Open browser: http://localhost:8081"
echo ""
echo "  3. Create your first account (admin user)"
echo ""
echo "  4. Create a project and add secrets"
echo ""
echo "Kubernetes Integration:"
echo ""
echo "  After creating secrets in the dashboard, sync them to Kubernetes:"
echo ""
echo "  1. Install Infisical Kubernetes Operator (optional):"
echo "     helm upgrade --install infisical-operator infisical/operator \\"
echo "       --namespace infisical \\"
echo "       --set infisical.token=<your-service-token>"
echo ""
echo "  2. Create InfisicalSecret CR to sync secrets as K8s secrets"
echo ""
echo "Example InfisicalSecret:"
echo ""
echo "  apiVersion: infisical.com/v1alpha1"
echo "  kind: InfisicalSecret"
echo "  metadata:"
echo "    name: my-app-secrets"
echo "    namespace: default"
echo "  spec:"
echo "    authentication:"
echo "      serviceAccountName: my-app-sa"
echo "    infisicalSecret:"
echo "      secretPath: /"
echo "      environmentName: dev"
echo "    managedSecretReference:"
echo "      secretName: my-app-secrets"
echo "      secretType: Opaque"
echo ""
echo "Resources:"
echo "  - Infisical Docs: https://infisical.com/docs/documentation/getting-started/introduction"
echo "  - GitHub: https://github.com/Infisical/infisical"
echo "  - Kubernetes Operator: https://infisical.com/docs/documentation/getting-started/kubernetes"
echo ""
