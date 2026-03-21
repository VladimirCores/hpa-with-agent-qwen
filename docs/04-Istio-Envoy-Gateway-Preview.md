# Istio with Envoy Gateway Installation (Preview)

This document describes the upcoming step for installing Istio service mesh with Envoy Gateway using Helm.

## Overview

After completing the Talos cluster bootstrap and Kubernetes components installation, this step adds:

1. **Istio Service Mesh** - Traffic management, security, and observability
2. **Envoy Gateway** - Kubernetes-native Envoy proxy management
3. **Helm** - Package manager for Kubernetes

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Talos Kubernetes Cluster                     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Istio Service Mesh                    │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │  istiod     │  │  istiod     │  │  istiod     │      │   │
│  │  │  (control   │  │  (control   │  │  (control   │      │   │
│  │  │   plane)    │  │   plane)    │  │   plane)    │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Envoy Gateway Components                    │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │  Envoy      │  │  Envoy      │  │  Envoy      │      │   │
│  │  │  Proxy      │  │  Proxy      │  │  Proxy      │      │   │
│  │  │  (Ingress)  │  │  (Sidecar)  │  │  (Egress)   │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Your Applications                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │   App A     │  │   App B     │  │   App C     │      │   │
│  │  │  + Envoy    │  │  + Envoy    │  │  + Envoy    │      │   │
│  │  │  (sidecar)  │  │  (sidecar)  │  │  (sidecar)  │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Components to Install

| Component | Version | Purpose |
|-----------|---------|---------|
| Helm | latest | Kubernetes package manager |
| Istio | latest | Service mesh control plane |
| Istio CNI | latest | CNI plugin for Istio |
| Envoy Gateway | latest | Envoy proxy management |
| Kiali | bundled | Service mesh observability |
| Grafana | bundled | Metrics dashboards |

## Prerequisites (Coming Soon)

- Talos cluster bootstrapped (see `03-Talos-Configuration.md`)
- Kubernetes components installed (CNI, metrics-server)
- `helm` installed on your host machine
- Cluster admin access

### Install Helm

```bash
# Download and install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version
```

## Configuration (Preview)

### Environment Variables

The following variables will be added to `.env`:

```bash
# Istio Configuration
ISTIO_VERSION=latest
ISTIO_NAMESPACE=istio-system
ISTIO_PROFILE=default

# Envoy Gateway Configuration
ENVOY_GATEWAY_VERSION=latest
ENVOY_GATEWAY_NAMESPACE=envoy-gateway-system

# Gateway Configuration
GATEWAY_TYPE=LoadBalancer
GATEWAY_REPLICAS=2
```

## Usage (Preview)

### Quick Start (Automated)

```bash
# Install Istio with Envoy Gateway
./scripts/istio-install.sh

# Verify installation
./scripts/istio-verify.sh
```

### Manual Steps (Preview)

#### Step 1: Add Helm Repositories

```bash
# Add Istio repository
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Add Envoy Gateway repository
helm repo add envoy-gateway https://artifacthub.io/packages/helm/envoy-gateway/envoy-gateway
helm repo update
```

#### Step 2: Install Istio

```bash
# Create namespace
kubectl create namespace istio-system

# Install Istio base (CRDs)
helm install istio-base istio/base -n istio-system

# Install Istiod (control plane)
helm install istiod istio/istiod -n istio-system \
  --set pilot.autoscaleMin=1 \
  --set pilot.autoscaleMax=3 \
  --set pilot.resources.requests.cpu=100m \
  --set pilot.resources.requests.memory=128Mi
```

#### Step 3: Install Istio Ingress Gateway

```bash
# Install ingress gateway
helm install istio-ingressgateway istio/gateway -n istio-system \
  --set service.type=LoadBalancer \
  --set autoscaleMin=1 \
  --set autoscaleMax=3
```

#### Step 4: Install Envoy Gateway

```bash
# Create namespace
kubectl create namespace envoy-gateway-system

# Install Envoy Gateway
helm install envoy-gateway envoy-gateway/envoy-gateway \
  -n envoy-gateway-system \
  --create-namespace
```

#### Step 5: Enable Sidecar Injection

```bash
# Label namespace for automatic sidecar injection
kubectl label namespace default istio-injection=enabled

# Or configure per-deployment
# Add to your deployment spec:
# spec:
#   template:
#     metadata:
#       annotations:
#         sidecar.istio.io/inject: "true"
```

## Verification (Preview)

### Check Istio Installation

```bash
# Check Istio pods
kubectl get pods -n istio-system

# Check Istio components
istioctl analyze

# Verify proxy status
istioctl proxy-status
```

### Check Envoy Gateway

```bash
# Check Envoy Gateway pods
kubectl get pods -n envoy-gateway-system

# Check Gateway API resources
kubectl get gatewayclasses
kubectl get gateways
kubectl get httproutes
```

### Test Service Mesh

```bash
# Deploy sample application
kubectl apply -f samples/httpbin/httpbin.yaml

# Test traffic management
istioctl authn tls-check <pod-name>
```

## Scripts (Coming Soon)

### istio-install.sh

The installation script will perform:

1. **Prerequisites Check** - Verifies helm, kubectl, cluster ready
2. **Add Helm Repos** - Adds Istio and Envoy Gateway repositories
3. **Install Istio Base** - Installs CRDs
4. **Install Istiod** - Deploys control plane
5. **Install Ingress Gateway** - Deploys ingress proxy
6. **Install Envoy Gateway** - Deploys Envoy Gateway controller
7. **Enable Sidecar Injection** - Configures namespace labeling
8. **Verification** - Checks all components

### istio-verify.sh

The verification script will check:

- Istio control plane health
- Envoy proxy connectivity
- Gateway API resources
- Sidecar injection status
- mTLS configuration

## Migration Guide

### From Existing Service Mesh

If migrating from another service mesh:

1. Review Istio's [migration guide](https://istio.io/latest/docs/ops/diagnostic-tools/migration/)
2. Test in a non-production environment first
3. Use Istio's traffic shifting for gradual migration

### Application Changes

Most applications require no code changes. Add sidecar injection:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    istio-injection: enabled
```

## Next Steps

After completing this step:

1. ✓ Istio service mesh installed
2. ✓ Envoy Gateway configured
3. ✓ Sidecar injection enabled
4. ✓ Traffic management available

**Future:** Configure HPA with Istio metrics, set up observability dashboards

## Resources

- [Istio Documentation](https://istio.io/latest/docs/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [Helm Charts](https://github.com/istio/istio/releases)
- [Gateway API](https://gateway-api.sigs.k8s.io/)

---

> **Note:** This document is a preview. The actual implementation scripts and detailed steps will be provided in the next iteration.
