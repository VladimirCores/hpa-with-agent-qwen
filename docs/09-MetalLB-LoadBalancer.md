# MetalLB LoadBalancer Setup

This guide covers installing and using MetalLB to provide LoadBalancer-type Services for your Talos Kubernetes cluster.

## Overview

MetalLB is a load balancer implementation for bare-metal Kubernetes clusters. It provides external IP addresses for Services of type `LoadBalancer`, enabling external traffic to reach your applications.

### How MetalLB Works

```
External Client
       │
       ▼ (ARP request for 192.168.123.200)
┌──────────────────────────────────────┐
│  Node (Leader) - ARP Response        │
│  ┌──────────────────────────────┐   │
│  │  MetalLB Speaker Pod         │   │
│  └──────────────────────────────┘   │
│         │                            │
│         ▼                            │
│  ┌──────────────────────────────┐   │
│  │  Service (LoadBalancer)      │   │
│  │  External IP: 192.168.123.200│   │
│  └──────────────────────────────┘   │
│         │                            │
│         ▼                            │
│  ┌──────────────────────────────┐   │
│  │  Pods (Endpoints)            │   │
│  └──────────────────────────────┘   │
└──────────────────────────────────────┘
```

### MetalLB Modes

| Mode | Description | Use Case | Pros | Cons |
|------|-------------|----------|------|------|
| **Layer 2** (default) | Uses ARP/NDP to announce service IPs | Simple setups, NAT networks | Easy setup, no special hardware | One node active at a time |
| **BGP** | Uses BGP protocol to advertise routes | Production, multi-node clusters | ECMP load distribution, true HA | Requires BGP-capable router |

> **For this cluster**: We use **Layer 2 mode** because it works with libvirt NAT networks and requires no special network equipment.

---

## Prerequisites

- Talos cluster bootstrapped (`./scripts/talos-bootstrap.sh`)
- Kubernetes components installed (CNI) (`./scripts/k8s-components.sh`)
- `kubectl` configured
- `helm` (optional, recommended for MetalLB installation)

---

## Installation

### Quick Install

The easiest way to install MetalLB is using the automated script:

```bash
# Install Cilium + MetalLB
./scripts/k8s-components.sh --with-metallb

# Install all components (CNI + metrics + MetalLB)
./scripts/k8s-components.sh --with-metrics --with-metallb

# Install MetalLB only
./scripts/k8s-components.sh -c metallb
```

### Configuration

Edit `.env` to customize MetalLB settings:

```bash
# MetalLB Version
METALLB_VERSION=0.14.8

# IP Address Pool (50 IPs for LoadBalancer Services)
METALLB_IP_POOL_START=192.168.123.200
METALLB_IP_POOL_END=192.168.123.250

# Mode: l2 (Layer 2) or bgp (BGP)
METALLB_MODE=l2

# Envoy Gateway dedicated IP (optional)
# Reserve this IP specifically for Envoy Gateway
ENVOY_GATEWAY_LB_IP=192.168.123.199
```

### Manual Installation

If you prefer to install manually:

#### Step 1: Install MetalLB

**Using Helm (recommended):**

```bash
# Add MetalLB Helm repository
helm repo add metallb https://metallb.github.io/metallb
helm repo update

# Create namespace
kubectl create namespace metallb-system

# Install MetalLB
helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --version 0.14.8
```

**Using manifests:**

```bash
# Create namespace
kubectl create namespace metallb-system

# Apply MetalLB manifests
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

#### Step 2: Configure IP Address Pool

Create an `IPAddressPool` resource:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.123.200-192.168.123.250
  autoAssign: true
  avoidBuggyIPs: true
```

```bash
kubectl apply -f ip-pool.yaml
```

#### Step 3: Configure L2 Advertisement

For Layer 2 mode, create an `L2Advertisement`:

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-pool-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
```

```bash
kubectl apply -f l2-advertisement.yaml
```

---

## Verification

### Check MetalLB Status

```bash
# Check MetalLB pods
kubectl get pods -n metallb-system

# Expected output:
# NAME                          READY   STATUS    RESTARTS   AGE
# controller-xxxx-xxxx          1/1     Running   0          2m
# speaker-xxxx                  1/1     Running   0          2m
# speaker-yyyy                  1/1     Running   0          2m

# Check IP pools
kubectl get ipaddresspools.metallb.io -n metallb-system

# Check advertisements
kubectl get l2advertisements.metallb.io -n metallb-system
```

### Test LoadBalancer Service

Create a test Service:

```yaml
# docs/examples/loadbalancer-test.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  labels:
    app: nginx-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-lb
spec:
  type: LoadBalancer
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
```

```bash
# Apply test deployment
kubectl apply -f docs/examples/loadbalancer-test.yaml

# Watch Service for external IP assignment
kubectl get svc nginx-test-lb -w

# Expected output:
# NAME              TYPE           CLUSTER-IP      EXTERNAL-IP       PORT(S)        AGE
# nginx-test-lb     LoadBalancer   10.96.100.50    192.168.123.200   80:30000/TCP   1m
```

### Test Connectivity

From the host machine:

```bash
# Test the LoadBalancer
curl http://192.168.123.200

# Expected: nginx welcome page HTML
```

---

## Envoy Gateway Integration

### How It Works

When you install Istio with Envoy Gateway, the following happens automatically:

1. Envoy Gateway creates a `Gateway` resource
2. The Gateway controller creates a `Service` of type `LoadBalancer`
3. MetalLB detects the LoadBalancer Service and assigns an external IP
4. External traffic flows: Client → MetalLB IP → Envoy Gateway → Your services

```
External Client
       │
       ▼ (192.168.123.199)
┌──────────────────────┐
│  MetalLB             │
│  (L2 Advertisement)  │
└──────────────────────┘
       │
       ▼
┌──────────────────────┐
│  Envoy Gateway       │
│  Service (LB)        │
│  External IP: .199   │
└──────────────────────┘
       │
       ▼
┌──────────────────────┐
│  Envoy Pods          │
│  (istio-ingress)     │
└──────────────────────┘
       │
       ▼
┌──────────────────────┐
│  Your Services       │
│  (HTTPRoutes)        │
└──────────────────────┘
```

### Reserved IP for Envoy Gateway

To ensure Envoy Gateway always gets the same external IP:

1. **Set in `.env`:**

```bash
ENVOY_GATEWAY_LB_IP=192.168.123.199
```

2. **Re-run MetalLB installation:**

```bash
./scripts/k8s-components.sh --with-metallb
```

This creates a dedicated `IPAddressPool` for Envoy Gateway:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: envoy-gateway-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.123.199
  autoAssign: false  # Only assigned via annotation
```

3. **Install Istio with Envoy Gateway:**

```bash
./scripts/istio-install.sh
```

The Envoy Gateway Service will automatically receive the reserved IP.

### Manual Gateway IP Assignment

If you want to manually assign a specific IP to any Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-gateway
  annotations:
    metallb.universe.tf/address-pool: envoy-gateway-pool
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.123.199
  # ... rest of spec
```

---

## IP Pool Planning

### Your Network Layout

```
192.168.123.1      - Gateway (libvirt network)
192.168.123.10     - talos-master (static DHCP reservation)
192.168.123.20     - talos-worker-1 (static DHCP reservation)
192.168.123.21     - talos-worker-2 (static DHCP reservation)
192.168.123.2-254  - DHCP range (dynamic assignments)

192.168.123.199    - Envoy Gateway (reserved, if configured)
192.168.123.200-250 - MetalLB general pool (50 IPs)
192.168.123.251-254 - Reserved for future use
```

### IP Pool Sizing

| Pool | Range | Count | Purpose |
|------|-------|-------|---------|
| General | 192.168.123.200-250 | 50 IPs | Regular LoadBalancer Services |
| Envoy Gateway | 192.168.123.199 | 1 IP | Envoy Gateway ingress |
| **Total** | - | **51 IPs** | - |

> **Tip**: 50 IPs is more than enough for HPA study workloads. Adjust if you need more or fewer.

---

## Usage Examples

### Example 1: Simple LoadBalancer Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app-lb
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

MetalLB automatically assigns an IP from the pool.

### Example 2: Multiple Services

```yaml
# Service 1
apiVersion: v1
kind: Service
metadata:
  name: web-app
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
  - port: 80

---
# Service 2
apiVersion: v1
kind: Service
metadata:
  name: api-service
spec:
  type: LoadBalancer
  selector:
    app: api
  ports:
  - port: 3000
```

Each service gets a unique IP from the pool.

### Example 3: HPA with LoadBalancer

```yaml
# Deployment with HPA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scalable-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: scalable-app
  template:
    metadata:
      labels:
        app: scalable-app
    spec:
      containers:
      - name: app
        image: nginx
        resources:
          requests:
            cpu: 100m
        ports:
        - containerPort: 80
---
# LoadBalancer Service
apiVersion: v1
kind: Service
metadata:
  name: scalable-app-lb
spec:
  type: LoadBalancer
  selector:
    app: scalable-app
  ports:
  - port: 80
---
# HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: scalable-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: scalable-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

Test scaling:

```bash
# Generate load
kubectl run -i --tty load-generator --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://$(kubectl get svc scalable-app-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); done"

# Watch HPA scaling
kubectl get hpa scalable-app-hpa -w

# Watch LoadBalancer IP
kubectl get svc scalable-app-lb
```

---

## Troubleshooting

### Service Stuck in Pending State

**Symptom:** `EXTERNAL-IP` shows `<pending>` for extended time

```bash
# Check MetalLB logs
kubectl logs -n metallb-system -l component=controller
kubectl logs -n metallb-system -l component=speaker

# Check IP pool status
kubectl get ipaddresspools.metallb.io -n metallb-system

# Check events
kubectl describe svc <service-name>
```

**Common causes:**
- IP pool exhausted (all IPs assigned)
- MetalLB pods not running
- Missing L2Advertisement configuration

**Solution:**

```bash
# Expand IP pool in .env
METALLB_IP_POOL_END=192.168.123.254

# Re-run installation
./scripts/k8s-components.sh --with-metallb
```

### IP Address Conflicts

**Symptom:** Service unreachable or intermittent connectivity

```bash
# Check current IP assignments
kubectl get svc -A -o wide | grep LoadBalancer

# Check MetalLB IP pool usage
kubectl get ipaddresspools.metallb.io -n metallb-system -o yaml
```

**Solution:**

Ensure your MetalLB IP range doesn't overlap with:
- DHCP reservations (MASTER_IP, WORKER IPs)
- Other static IPs in your network
- Other MetalLB installations

### L2 Advertisement Issues

**Symptom:** Service has external IP but is unreachable

```bash
# Check L2 advertisements
kubectl get l2advertisements.metallb.io -n metallb-system

# Check which node is leader
kubectl logs -n metallb-system -l component=speaker | grep "leader"
```

**Solution:**

For multi-interface nodes, specify the correct interface:

```bash
# In .env
METALLB_L2_INTERFACES=eth0
```

Then re-run installation.

### BGP Peering Issues (BGP Mode)

**Symptom:** BGP session not established

```bash
# Check BGP peers
kubectl get bgppeers.metallb.io -n metallb-system -o wide

# Check BGP speaker logs
kubectl logs -n metallb-system -l component=speaker
```

**Solution:**

- Verify BGP router configuration
- Check ASN numbers match
- Ensure network connectivity to BGP peer

### MetalLB Pods Not Starting

```bash
# Check pod status
kubectl get pods -n metallb-system

# Check events
kubectl describe pod -n metallb-system -l component=controller
```

**Common issues:**
- Insufficient permissions
- CNI conflicts
- Resource constraints

**Solution:**

```bash
# Restart MetalLB
kubectl delete pods -n metallb-system --all

# Reinstall
./scripts/k8s-components.sh -c metallb
```

---

## Advanced Configuration

### Multiple IP Pools

You can create multiple pools for different purposes:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.123.200-192.168.123.220
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: staging-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.123.221-192.168.123.230
```

Assign pools to services via annotations:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: production-app
  annotations:
    metallb.universe.tf/address-pool: production-pool
spec:
  type: LoadBalancer
```

### Node Selectors

Control which nodes can become ARP leaders:

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: worker-only
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
  nodeSelectors:
  - matchLabels:
      node-role.kubernetes.io/worker: "true"
```

---

## Cleanup

### Remove MetalLB

```bash
# Uninstall MetalLB
helm uninstall metallb -n metallb-system

# Or if installed via manifests
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Delete namespace
kubectl delete namespace metallb-system
```

### Release Specific IP

Delete and recreate the Service, or change its type:

```bash
# Change to ClusterIP (releases external IP)
kubectl patch svc <service-name> -p '{"spec": {"type": "ClusterIP"}}'
```

---

## Next Steps

1. **Install Istio with Envoy Gateway:**
   ```bash
   ./scripts/istio-install.sh
   ```

2. **Create Gateway API routes:**
   - See: `docs/04-Istio-Envoy-Gateway-Integration.md`

3. **Test HPA with LoadBalancer:**
   - See: `docs/06-HPA-Study-Guide.md`

4. **Explore MetalLB metrics:**
   ```bash
   kubectl port-forward -n metallb-system svc/metallb-controller 8080:8080
   ```

---

## References

- [MetalLB Official Documentation](https://metallb.universe.tf/)
- [MetalLB GitHub Repository](https://github.com/metallb/metallb)
- [Kubernetes LoadBalancer Services](https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
