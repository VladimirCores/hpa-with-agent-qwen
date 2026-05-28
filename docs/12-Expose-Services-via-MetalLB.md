# Expose Hubble UI & Kubernetes Dashboard via MetalLB

## Overview

Hubble UI and Kubernetes Dashboard are now automatically exposed via MetalLB LoadBalancer services, making them accessible through stable external IP addresses without requiring `kubectl port-forward`.

## Architecture

```
External Browser
       │
       ├─ http://192.168.123.200 ──────────────────┐
       │                                            ▼
       │                              ┌─────────────────────────┐
       ├─ https://192.168.123.201 ───▶│  MetalLB LoadBalancer   │
       │                              │  (L2 Advertisement)     │
       └──────────────────────────────┤                         │
                                      └─────────────────────────┘
                                               │
                          ┌────────────────────┴────────────────────┐
                          │                                         │
                          ▼                                         ▼
              ┌───────────────────┐                   ┌───────────────────┐
              │   Hubble UI       │                   │  K8s Dashboard    │
              │   Port 80         │                   │  Port 443→8443    │
              │   (Network Flows) │                   │  (Cluster Mgmt)   │
              └───────────────────┘                   └───────────────────┘
```

## Configuration

Add to your `.env` file:

```bash
# =============================================================================
# Expose Internal Services via MetalLB LoadBalancer
# =============================================================================

# Expose Hubble UI via MetalLB LoadBalancer
# Default: true (Hubble UI gets dedicated LoadBalancer IP)
EXPOSE_HUBBLE_UI=true

# Optional: Assign specific IP to Hubble UI (leave empty for auto-assignment)
HUBBLE_UI_LB_IP=192.168.123.200

# Expose Kubernetes Dashboard via MetalLB LoadBalancer
# Default: true (Dashboard gets dedicated LoadBalancer IP)
EXPOSE_K8S_DASHBOARD=true

# Optional: Assign specific IP to K8s Dashboard (leave empty for auto-assignment)
K8S_DASHBOARD_LB_IP=192.168.123.201
```

## Default Behavior

When you run `./scripts/k8s-components.sh --with-metallb`:

1. **MetalLB is installed** with configured IP pool
2. **Hubble UI is exposed** (if `HUBBLE_ENABLED=true`)
   - Service type changed to `LoadBalancer`
   - External IP assigned from pool
   - Accessible at `http://<EXTERNAL_IP>`

3. **Kubernetes Dashboard is exposed** (if installed)
   - Service type changed to `LoadBalancer`
   - External IP assigned from pool
   - Accessible at `https://<EXTERNAL_IP>`

## Usage Examples

### Auto-Assign IPs (Default)

```bash
# In .env
EXPOSE_HUBBLE_UI=true
EXPOSE_K8S_DASHBOARD=true
# Leave IPs empty for auto-assignment

# Install
./scripts/k8s-components.sh --with-metallb
```

**Output:**
```
═══════════════════════════════════════════════════════════
  External Service Access via MetalLB
═══════════════════════════════════════════════════════════

  Hubble UI (Network Observability):
    URL: http://192.168.123.200
    Status: 192.168.123.200

  Kubernetes Dashboard (Cluster Management):
    URL: https://192.168.123.201
    Status: 192.168.123.201
    Token: kubectl -n kubernetes-dashboard create token admin-user

═══════════════════════════════════════════════════════════
```

### Assign Static IPs

```bash
# In .env
EXPOSE_HUBBLE_UI=true
HUBBLE_UI_LB_IP=192.168.123.200

EXPOSE_K8S_DASHBOARD=true
K8S_DASHBOARD_LB_IP=192.168.123.201

# Install
./scripts/k8s-components.sh --with-metallb
```

### Disable Exposure

```bash
# In .env
EXPOSE_HUBBLE_UI=false
EXPOSE_K8S_DASHBOARD=false

# Install (services remain ClusterIP/NodePort)
./scripts/k8s-components.sh --with-metallb
```

## Accessing Services

### Hubble UI

**URL:** `http://<HUBBLE_UI_LB_IP>`

**Features:**
- 🔍 Real-time network flow visualization
- 📊 Service dependency maps
- 🔐 Policy enforcement tracking
- 🐛 Connectivity troubleshooting

**Example:**
```
Open browser: http://192.168.123.200

You'll see:
- Network topology graph
- Live flow events
- DNS query logs
- Policy decisions
- HTTP/gRPC traces
```

### Kubernetes Dashboard

**URL:** `https://<K8S_DASHBOARD_LB_IP>`

**Authentication:**
```bash
# Get login token
kubectl -n kubernetes-dashboard create token admin-user

# Or use saved token (from bootstrap)
cat talos-cluster/dashboard-admin-token.txt
```

**Features:**
- 📦 Workload management
- 🔧 Resource monitoring
- 📊 Cluster overview
- 🐛 Log viewer
- 🔐 RBAC management

**Example:**
```
Open browser: https://192.168.123.201
(Accept self-signed certificate warning)

Login with token:
eyJhbGciOiJSUzI1NiIsImtpZCI6...
```

## IP Pool Planning

### Recommended Layout

```
192.168.123.199    - Envoy Gateway (if configured)
192.168.123.200    - Hubble UI
192.168.123.201    - Kubernetes Dashboard
192.168.123.202-250 - General pool (49 IPs)
```

### Configuration Example

```bash
# MetalLB general pool (exclude dedicated IPs)
METALLB_IP_POOL_START=192.168.123.202
METALLB_IP_POOL_END=192.168.123.250

# Dedicated service IPs
HUBBLE_UI_LB_IP=192.168.123.200
K8S_DASHBOARD_LB_IP=192.168.123.201
ENVOY_GATEWAY_LB_IP=192.168.123.199
```

## Troubleshooting

### Service Shows "pending" External IP

```bash
# Check MetalLB controller logs
kubectl logs -n metallb-system -l component=controller

# Check IP pool availability
kubectl get ipaddresspools.metallb.io -n metallb-system

# Verify L2 advertisement
kubectl get l2advertisements.metallb.io -n metallb-system
```

**Common causes:**
- IP pool exhausted
- MetalLB pods not ready
- Service namespace mismatch

### Hubble UI Not Accessible

```bash
# Check Hubble UI service
kubectl get svc hubble-ui -n kube-system

# Verify Hubble pods
kubectl get pods -n kube-system -l k8s-app=hubble-ui

# Check service endpoints
kubectl get endpoints hubble-ui -n kube-system
```

**Solutions:**
```bash
# Re-patch service type
kubectl patch svc hubble-ui -n kube-system -p '{"spec":{"type":"LoadBalancer"}}'

# Restart MetalLB speaker
kubectl rollout restart daemonset speaker -n metallb-system
```

### Kubernetes Dashboard Certificate Warning

This is **expected** - the dashboard uses self-signed certificates.

**To proceed:**
1. Click "Advanced" in browser
2. Click "Proceed to <IP> (unsafe)"
3. Login with token

**Alternative:** Add certificate exception:
```bash
# Accept certificate
curl -k https://<DASHBOARD_IP> -o /dev/null
```

### Token Expired or Invalid

```bash
# Create new token (valid for 1 hour by default)
kubectl -n kubernetes-dashboard create token admin-user

# Create long-lived token (24 hours)
kubectl -n kubernetes-dashboard create token admin-user --duration=24h

# Create permanent token via Secret
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF
```

## Manual Service Creation

If you need to manually create LoadBalancer services:

### Hubble UI LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hubble-ui-lb
  namespace: kube-system
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.123.200  # Optional
  selector:
    k8s-app: hubble-ui
  ports:
  - port: 80
    targetPort: 80
```

### Kubernetes Dashboard LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard-lb
  namespace: kubernetes-dashboard
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.123.201  # Optional
  selector:
    k8s-app: kubernetes-dashboard
  ports:
  - port: 443
    targetPort: 8443
```

## Comparison: port-forward vs MetalLB

| Feature | port-forward | MetalLB LoadBalancer |
|---------|--------------|----------------------|
| **Setup** | Manual each time | Automatic on install |
| **Stability** | Tied to kubectl process | Permanent Service |
| **Access** | localhost only | Any host on network |
| **Sharing** | Single user | Multiple users |
| **URL** | http://localhost:8080 | http://192.168.123.200 |
| **Best for** | Quick testing | Production use |

## Next Steps

1. **Access Hubble UI:**
   ```bash
   # Get IP
   kubectl get svc hubble-ui -n kube-system
   
   # Open browser
   # http://<EXTERNAL_IP>
   ```

2. **Access Kubernetes Dashboard:**
   ```bash
   # Get IP and token
   kubectl get svc kubernetes-dashboard -n kubernetes-dashboard
   kubectl -n kubernetes-dashboard create token admin-user
   
   # Open browser
   # https://<EXTERNAL_IP>
   ```

3. **Install Envoy Gateway:**
   ```bash
   ./scripts/istio-install.sh
   ```

4. **Monitor cluster:**
   - Use Hubble UI for network flows
   - Use Dashboard for resource management
   - Both accessible via stable external IPs

## Summary

✅ **Hubble UI** automatically exposed via MetalLB (default: enabled)  
✅ **Kubernetes Dashboard** automatically exposed via MetalLB (default: enabled)  
✅ **Static IP assignment** option for predictable URLs  
✅ **Auto-assignment** from pool when IP not specified  
✅ **Access instructions** printed after installation  
✅ **No port-forward needed** - permanent LoadBalancer services  

All services are configured through `.env` for easy customization!
