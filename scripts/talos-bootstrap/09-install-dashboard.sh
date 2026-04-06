#!/bin/bash
# =============================================================================
# Step 09: Install Kubernetes Dashboard
# =============================================================================
# Installs Kubernetes Dashboard for web-based cluster verification.
# Creates admin user with cluster-admin privileges.
# Provides access instructions.
# =============================================================================

set -euo pipefail

STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[9/10] Installing Kubernetes Dashboard..."
echo "  This will install the Kubernetes Dashboard for web-based cluster verification"
echo "  Dashboard URL: https://localhost:8443 (via kubectl port-forward)"
echo ""

# Check if dashboard is already installed
echo "  Checking if dashboard is already installed..."
if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get namespace kubernetes-dashboard >/dev/null 2>&1; then
    echo "  ✓ Kubernetes Dashboard namespace already exists"
    echo ""
else
    # Install Kubernetes Dashboard
    echo "  Phase 1: Installing Kubernetes Dashboard..."
    echo "  Applying dashboard manifest..."

    DASHBOARD_URL="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"

    if KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl apply -f "$DASHBOARD_URL" 2>&1; then
        echo "  ✓ Dashboard manifest applied"
    else
        echo "  ERROR: Failed to apply dashboard manifest"
        exit 1
    fi

    echo ""

    # Create admin user
    echo "  Phase 2: Creating admin user with cluster-admin privileges..."

    cat <<EOF | KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

    echo "  ✓ Admin user created with cluster-admin role"
    echo ""

    # Get admin token
    echo "  Phase 3: Retrieving admin token..."
    TOKEN_WAIT=0
    TOKEN_TIMEOUT=60

    while [[ $TOKEN_WAIT -lt $TOKEN_TIMEOUT ]]; do
        TOKEN=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || true)
        
        if [[ -n "$TOKEN" ]]; then
            echo "  ✓ Admin token retrieved (${TOKEN_WAIT}s)"
            break
        fi
        
        if [[ $((TOKEN_WAIT % 10)) -eq 0 ]]; then
            echo "    Waiting for token... (${TOKEN_WAIT}s)"
        fi
        
        sleep 5
        TOKEN_WAIT=$((TOKEN_WAIT + 5))
    done

    if [[ -z "$TOKEN" ]]; then
        echo "  WARNING: Could not retrieve admin token"
        echo "  You can get it later with:"
        echo "    kubectl -n kubernetes-dashboard create token admin-user"
    else
        # Save token to file
        echo "$TOKEN" > "$CONFIG_DIR/dashboard-admin-token.txt"
        chmod 600 "$CONFIG_DIR/dashboard-admin-token.txt"
        echo "  ✓ Token saved to: $CONFIG_DIR/dashboard-admin-token.txt"
    fi

    echo ""

    # Wait for dashboard pod to be running
    echo "  Phase 4: Waiting for dashboard pods to be ready..."
    POD_WAIT=0
    POD_TIMEOUT=120

    while [[ $POD_WAIT -lt $POD_TIMEOUT ]]; do
        POD_STATUS=$(KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kubernetes-dashboard --no-headers 2>&1 || true)
        RUNNING=$(echo "$POD_STATUS" | grep -c "Running" 2>/dev/null || echo "0")
        RUNNING=$(echo "$RUNNING" | tr -d '[:space:]')
        TOTAL=$(echo "$POD_STATUS" | grep -c "." 2>/dev/null || echo "0")
        TOTAL=$(echo "$TOTAL" | tr -d '[:space:]')
        
        if [[ $RUNNING -ge $TOTAL ]] && [[ $TOTAL -gt 0 ]]; then
            echo "  ✓ All $TOTAL dashboard pods Running (${POD_WAIT}s)"
            echo ""
            echo "  Dashboard pods:"
            KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kubernetes-dashboard 2>&1 | while IFS= read -r line; do
                echo "    $line"
            done
            break
        fi
        
        # Show progress
        PENDING=$((TOTAL - RUNNING))
        if [[ $((POD_WAIT % 15)) -eq 0 ]]; then
            echo "    Pods: $RUNNING Running, $PENDING Pending (${POD_WAIT}s)"
        fi
        
        sleep 5
        POD_WAIT=$((POD_WAIT + 5))
    done

    if [[ $POD_WAIT -ge $POD_TIMEOUT ]]; then
        echo "  WARNING: Not all dashboard pods running after ${POD_TIMEOUT}s"
        echo "  Current pod status:"
        KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl get pods -n kubernetes-dashboard 2>&1 | while IFS= read -r line; do
            echo "    $line"
        done
    fi

    echo ""
fi

# Expose dashboard via NodePort for direct host access (always do this)
echo "  Phase 5: Exposing dashboard via NodePort for direct access..."
echo "  Patching kubernetes-dashboard service to NodePort type..."

KUBECONFIG="$CONFIG_DIR/kubeconfig" kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8443,"nodePort":30443}]}}' 2>/dev/null || true

echo "  ✓ Dashboard exposed on NodePort 30443"
echo ""

# Start automatic port-forward for direct host access
echo "  Phase 6: Starting automatic port-forward for host access..."
echo "  This makes the dashboard accessible at https://localhost:8443"
echo ""

# Kill any existing port-forward
pkill -f "kubectl.*port-forward.*kubernetes-dashboard.*8443" 2>/dev/null || true
sleep 1

# Start port-forward in background
nohup kubectl \
    --kubeconfig "$CONFIG_DIR/kubeconfig" \
    -n kubernetes-dashboard \
    port-forward svc/kubernetes-dashboard 8443:443 \
    > /tmp/dashboard-portforward.log 2>&1 &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
PF_WAIT=0
PF_TIMEOUT=30

while [[ $PF_WAIT -lt $PF_TIMEOUT ]]; do
    if curl -sk --connect-timeout 2 https://localhost:8443 -o /dev/null 2>/dev/null; then
        echo "  ✓ Port-forward started (PID: $PORT_FORWARD_PID)"
        echo "  ✓ Dashboard accessible at: https://localhost:8443"
        break
    fi
    
    if [[ $((PF_WAIT % 5)) -eq 0 ]]; then
        echo "    Starting port-forward... (${PF_WAIT}s)"
    fi
    
    sleep 1
    PF_WAIT=$((PF_WAIT + 1))
done

if [[ $PF_WAIT -ge $PF_TIMEOUT ]]; then
    echo "  WARNING: Port-forward may not be ready"
    echo "  Manual start: kubectl --kubeconfig $CONFIG_DIR/kubeconfig -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443"
fi

echo ""

# Get VM IPs for access instructions (from .env)
echo "  Retrieving node IP addresses..."
MASTER_VM_IP="${MASTER_IP:-192.168.123.10}"
WORKER1_IP=$(echo "$WORKER_IP_BASE" | awk -F. '{print $1"."$2"."$3"."$4}')
WORKER2_IP=$(echo "$WORKER_IP_BASE" | awk -F. '{print $1"."$2"."$3"."$4+1}')

echo "  ✓ Node IPs: $MASTER_VM_IP (master), $WORKER1_IP (worker-1), $WORKER2_IP (worker-2)"

echo ""

# Summary
echo "  === Kubernetes Dashboard Installed ==="
echo ""
echo "  Web Access (from host machine):"
echo "    https://localhost:8443"
echo "    (Accept the self-signed certificate warning)"
echo ""
echo "  Login Token:"
echo "    Token file: $CONFIG_DIR/dashboard-admin-token.txt"
echo "    Or run: kubectl -n kubernetes-dashboard create token admin-user"
echo ""
echo "  Internal Access (from VM network):"
echo "    https://$MASTER_VM_IP:30443 (master)"
echo "    https://$WORKER1_IP:30443 (worker-1)"
echo "    https://$WORKER2_IP:30443 (worker-2)"
echo ""
echo "  To restart port-forward if needed:"
echo "    kubectl --kubeconfig $CONFIG_DIR/kubeconfig -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443"
echo ""
echo "  ✓ Kubernetes Dashboard installation complete"
echo ""
