# Istio + Envoy Gateway Integration

This guide covers the installation and integration of **Istio service mesh** with **Envoy Gateway** for ingress traffic management on your Talos Kubernetes cluster.

## Architecture

```
                              External Traffic
                                    │
                                    ▼
                          ┌─────────────────┐
                          │    MetalLB      │
                          │ 192.168.123.200  │
                          └────────┬────────┘
                                   │ LoadBalancer
                                   ▼
                    ┌──────────────────────────┐
                    │   Envoy Gateway          │
                    │   (Gateway API Ingress)  │
                    │   Namespace: envoy-      │
                    │   gateway-system         │
                    └────────┬─────────────────┘
                             │ HTTPRoute routing
                             ▼
                    ┌──────────────────────────┐
                    │   Istio Sidecar Proxy    │
                    │   (mTLS, telemetry,      │
                    │    traffic mgmt)         │
                    └────────┬─────────────────┘
                             │
                    ┌────────▼────────┐
                    │  Application    │
                    │  Pod (sidecar)  │
                    └─────────────────┘
```

| Component | Role | Namespace |
|-----------|------|-----------|
| **Istio (istiod)** | Service mesh control plane — sidecar injection, mTLS, telemetry | `istio-system` |
| **Envoy Gateway** | Gateway API ingress controller — north-south traffic | `envoy-gateway-system` |
| **Kiali** (optional) | Service mesh visualization | `istio-system` |
| **MetalLB** | LoadBalancer IP allocation | `metallb-system` |

### Key Design Decisions

1. **Envoy Gateway for ingress, Istio for mesh** — Envoy Gateway handles all north-south (external-to-cluster) traffic via Gateway API. Istio handles east-west (service-to-service) traffic with sidecar proxies, mTLS, and telemetry.

2. **Separate namespaces** — Istio and Envoy Gateway live in different namespaces for clear separation of concerns and independent lifecycle management.

3. **PERMISSIVE mTLS** — Istio is configured with PERMISSIVE mTLS mode so traffic from Envoy Gateway (which does not have an Istio sidecar) can still reach mesh services. Services within the mesh use STRICT mTLS between themselves.

## Prerequisites

- Talos cluster bootstrapped (see `03-Talos-Configuration.md`)
- Cilium CNI installed with kube-proxy replacement (recommended, see `05-Cilium-Setup.md`)
- MetalLB installed with an IP pool (see `09-MetalLB-LoadBalancer.md`)
- `helm` CLI installed
- `kubectl` configured with cluster access

## Installation

### Quick Start

```bash
# Option A: Install via dedicated script
./scripts/istio-install.sh

# Option B: Install via k8s-components orchestrator
./scripts/k8s-components.sh --with-istio

# Option C: Install only Envoy Gateway (without full Istio)
./scripts/istio-install.sh  # Then set ISTIO_ENABLED=false in .env
```

### Step-by-Step (What the Script Does)

The `istio-install.sh` script runs these steps:

| Step | Script | Description |
|------|--------|-------------|
| 01 | `01-check-prerequisites.sh` | Verifies helm, kubectl, cluster connectivity |
| 02 | `02-install-istio-base.sh` | Installs Istio CRDs via `istio/base` Helm chart |
| 03 | `03-install-istiod.sh` | Deploys Istio control plane via `istio/istiod` Helm chart |
| 04 | `04-install-envoy-gateway.sh` | Deploys Envoy Gateway + creates GatewayClass + Gateway with MetalLB IP |
| 05 | `05-configure-integration.sh` | Labels namespaces, configures mTLS, creates DestinationRules |
| 06 | `06-install-kiali.sh` | Installs Kiali visualization (if `KIALA_ENABLED=true`) |
| 07 | `07-verify.sh` | Verifies all components and shows access info |

### Environment Configuration

Add to `.env` (or use defaults):

```bash
# Istio Configuration
ISTIO_VERSION=1.22.0
ISTIO_NAMESPACE=istio-system
ISTIO_PROFILE=default
ISTIO_INGRESS_ENABLED=false       # Set true to also install Istio's own ingress gateway

# Envoy Gateway Configuration
ENVOY_GATEWAY_VERSION=1.1.0
ENVOY_GATEWAY_NAMESPACE=envoy-gateway-system
ENVOY_GATEWAY_REPLICAS=2
ENVOY_GATEWAY_LB_IP=192.168.123.200  # Must be within MetalLB pool range

# Kiali (requires Istio)
KIALA_ENABLED=false
```

### Image Caching

When `ISTIO_ENABLED=true` or `ENVOY_GATEWAY_ENABLED=true` in `.env`, the `populate-local-registry.sh` script caches these images:

| Image | Version | Component |
|-------|---------|-----------|
| `docker.io/istio/pilot` | `1.22.0` | Istio control plane |
| `docker.io/istio/proxyv2` | `1.22.0` | Istio sidecar proxy |
| `docker.io/envoyproxy/gateway` | `v1.1.0` | Envoy Gateway controller |
| `docker.io/envoyproxy/envoy` | `v1.31.0` | Envoy data-plane proxy |
| `quay.io/kiali/kiali` | `v1.73.0` | Kiali visualization |

## Verification

### Check Component Status

```bash
# Istio
kubectl get pods -n istio-system
kubectl get deployment istiod -n istio-system
kubectl get crd -l app.kubernetes.io/part-of=istio

# Envoy Gateway
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclasses
kubectl get gateways -n envoy-gateway-system

# Kiali (if installed)
kubectl get pods -n istio-system -l app=kiali
```

### Quick Health Check

```bash
# Run the verification script
./scripts/istio/07-verify.sh

# Test Envoy Gateway endpoint
curl -v http://192.168.123.200  # Should return 503 (no routes configured yet)

# Check sidecar injection labels
kubectl get namespace -l istio-injection=enabled
```

## Deploying a Sample Application

### Step 1: Create Namespace with Sidecar Injection

```bash
kubectl create namespace sample-app
kubectl label namespace sample-app istio-injection=enabled
```

### Step 2: Deploy Application

```yaml
# sample-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: sample-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
        - name: httpbin
          image: docker.io/kennethreitz/httpbin
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: sample-app
spec:
  selector:
    app: httpbin
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f sample-app.yaml
```

### Step 3: Create HTTPRoute for Envoy Gateway

```yaml
# httpbin-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: envoy-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: httpbin
          namespace: sample-app
          port: 80
```

```bash
kubectl apply -f httpbin-route.yaml
```

### Step 4: Verify Routing

```bash
# Test via Envoy Gateway
curl -v http://192.168.123.200/ip

# Check sidecar injection
kubectl get pods -n sample-app
# Each pod should have 2/2 containers (app + Istio sidecar)

# Check mTLS
istioctl authn tls-check $(kubectl get pod -n sample-app -l app=httpbin -o jsonpath='{.items[0].metadata.name}') -n sample-app
```

## Integration Details

### How Envoy Gateway Routes to Istio Mesh

1. Traffic arrives at Envoy Gateway's LoadBalancer IP (192.168.123.200)
2. An HTTPRoute matches the incoming request path and forwards to the backend Service
3. The Service selects Pods in a namespace with `istio-injection=enabled`
4. The Istio sidecar proxy intercepts inbound traffic to the Pod
5. The sidecar enforces mTLS, telemetry, and any configured traffic policies

### mTLS Configuration

- **Between services in the mesh**: `ISTIO_MUTUAL` (full mTLS) via DestinationRule
- **From Envoy Gateway to mesh services**: `PERMISSIVE` via PeerAuthentication (accepts both mTLS and plain TCP, upgrades to mTLS where possible)
- **External-to-Envoy Gateway**: Plain HTTP (terminated at the Gateway, forwarded via cluster IP)

### Sidecar Injection

- Namespaces labeled `istio-injection=enabled` automatically get sidecars injected into new Pods
- Envoy Gateway's control-plane deployment is annotated with `sidecar.istio.io/inject=false` to avoid injecting a sidecar into the gateway controller itself
- Existing Pods must be restarted after labeling a namespace to get the sidecar

## Monitoring

### Kiali

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Open: http://localhost:20001
```

Kiali provides:
- Service graph with mTLS status
- Traffic metrics (request rates, error rates, latency)
- Configuration validation
- Workload health

### Accessing Logs

```bash
# Istiod logs
kubectl logs -n istio-system deployment/istiod

# Envoy Gateway logs
kubectl logs -n envoy-gateway-system deployment/envoy-gateway

# Application pod with sidecar proxy logs
kubectl logs -n sample-app deployment/httpbin -c istio-proxy
```

## Troubleshooting

### Sidecar Not Injecting

```bash
# Check namespace label
kubectl get namespace sample-app --show-labels

# Check istiod is running
kubectl get pods -n istio-system -l app=istiod

# Check webhook configuration
kubectl get mutatingwebhookconfiguration -l app=istiod

# Restart deployment to trigger injection
kubectl rollout restart deployment -n sample-app
```

### Envoy Gateway Not Responding

```bash
# Check gateway status
kubectl get gateways -n envoy-gateway-system
kubectl describe gateway envoy-gateway -n envoy-gateway-system

# Check HTTPRoute status
kubectl get httproutes -n envoy-gateway-system
kubectl describe httproutes -n envoy-gateway-system

# Check MetalLB assigned IP
kubectl get svc -n envoy-gateway-system
```

### mTLS Issues

```bash
# Check PeerAuthentication
kubectl get peerauthentication -A

# Check DestinationRule
kubectl get destinationrule -A

# Verify TLS status for a specific pod
istioctl authn tls-check <pod-name> -n <namespace>
```

### Pods Stuck in CrashLoopBackOff

```bash
# Check sidecar proxy logs
kubectl logs <pod-name> -n <namespace> -c istio-proxy

# Check Istio sidecar status
istioctl proxy-status

# Restart with debug logging
kubectl annotate pod <pod-name> -n <namespace> sidecar.istio.io/logLevel=debug
```

## Uninstallation

```bash
# Remove HTTPRoutes and Gateways
kubectl delete httproutes --all -n envoy-gateway-system
kubectl delete gateway envoy-gateway -n envoy-gateway-system
kubectl delete gatewayclass envoy-gateway

# Uninstall Envoy Gateway
helm uninstall envoy-gateway -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system

# Uninstall Istio
helm uninstall istio-ingressgateway -n istio-system 2>/dev/null || true
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl delete namespace istio-system

# Remove CRDs (caution: this removes all Istio resources)
kubectl get crd -l app.kubernetes.io/part-of=istio -o name | xargs kubectl delete
```

## HPA Study Integration

With Istio + Envoy Gateway, HPA can use custom metrics from Istio telemetry:

```bash
# Install Prometheus Adapter for custom metrics (if not already)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace istio-system \
  --set prometheus.url=http://prometheus.istio-system:9090

# HPA based on requests per second
kubectl autoscale deployment httpbin -n sample-app \
  --cpu-percent=50 --min=1 --max=10
```

## Resources

- [Istio Documentation](https://istio.io/latest/docs/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [MetalLB Configuration](09-MetalLB-LoadBalancer.md)
- [HPA Study Guide](06-HPA-Study-Guide.md)
