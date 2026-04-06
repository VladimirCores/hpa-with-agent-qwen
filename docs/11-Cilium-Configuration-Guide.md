# Cilium Configuration Guide

This guide covers Cilium CNI configuration with kube-proxy replacement and Hubble UI for your Talos Kubernetes cluster.

## Overview

Cilium provides eBPF-based pod networking with advanced features:

- **kube-proxy replacement**: Cilium replaces kube-proxy with BPF-based service routing for better performance
- **Hubble UI**: Network observability and flow monitoring
- **L7 policies**: Application-aware networking

## Configuration Options

Add to your `.env` file:

```bash
# =============================================================================
# Cilium CNI Configuration
# =============================================================================

# Cilium Version
CILIUM_VERSION="1.19.1"

# Disable kube-proxy (Cilium replaces it with BPF-based service routing)
# Default: true (kube-proxy disabled, Cilium handles service routing)
# Set to false to keep kube-proxy running alongside Cilium
CILIUM_KUBE_PROXY_REPLACEMENT=true

# Hubble UI - Network observability
# Default: true (Hubble UI enabled for network flow monitoring)
# Set to false to disable Hubble and reduce resource usage
CILIUM_HUBBLE_ENABLED=true

# Hubble Relay - gRPC API for Hubble data
# Required for Hubble UI and CLI
CILIUM_HUBBLE_RELAY_ENABLED=true
```

## kube-proxy Replacement

### Enabled by Default (Recommended)

When `CILIUM_KUBE_PROXY_REPLACEMENT=true`:

**Benefits:**
- ✅ Better performance (BPF vs iptables/IPVS)
- ✅ Lower latency
- ✅ Reduced resource usage
- ✅ Native Talos Linux compatibility

**How it works:**
```
Traditional: Pod → kube-proxy (iptables/IPVS) → Service → Pod
Cilium BPF:  Pod → BPF program → Service → Pod
```

### Disabled (Hybrid Mode)

When `CILIUM_KUBE_PROXY_REPLACEMENT=false`:

**Use cases:**
- Testing/development
- Compatibility with legacy applications
- Gradual migration scenarios

**Behavior:**
- Both Cilium and kube-proxy run
- Cilium provides CNI functionality
- kube-proxy handles Service routing
- Higher resource usage

## Hubble UI

### Enabled by Default

When `CILIUM_HUBBLE_ENABLED=true`:

**Features:**
- 🔍 Network flow visualization
- 📊 Real-time traffic monitoring
- 🔐 Policy enforcement tracking
- 🐛 Troubleshooting assistance

**Access Hubble UI:**

```bash
# Port-forward to Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8080:80

# Open in browser
# http://localhost:8080
```

**Example Hubble UI View:**
```
┌─────────────────────────────────────────┐
│         Hubble Network Flow Map         │
│                                         │
│  ┌─────────┐      ┌──────────┐         │
│  │  Pod A  │─────▶│ Service  │         │
│  │ 10.0.1  │      │  80/TCP  │         │
│  └─────────┘      └──────────┘         │
│                        │                │
│                        ▼                │
│                 ┌──────────┐           │
│                 │  Pod B   │           │
│                 │ 10.0.2   │           │
│                 └──────────┘           │
│                                         │
│  Flow Details:                          │
│  - Source: 10.0.1:12345                │
│  - Destination: 10.0.2:80              │
│  - Protocol: TCP                       │
│  - Status: ✅ Allowed                  │
└─────────────────────────────────────────┘
```

### Disabled

When `CILIUM_HUBBLE_ENABLED=false`:

**Benefits:**
- Reduced resource usage (~200MB memory saved)
- Simpler deployment
- Suitable for resource-constrained environments

## Installation

### Quick Install with Defaults

```bash
# Install Cilium with kube-proxy replacement + Hubble UI
./scripts/k8s-components.sh
```

### Install with Custom Configuration

```bash
# Install Cilium only (uses .env settings)
./scripts/k8s-components.sh --cni-cilium

# Install Cilium + MetalLB
./scripts/k8s-components.sh --with-metallb

# Install everything
./scripts/k8s-components.sh --with-metrics --with-metallb
```

### Verify Installation

```bash
# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Check kube-proxy status
kubectl get daemonset kube-proxy -n kube-system

# Check Hubble (if enabled)
kubectl get pods -n kube-system -l k8s-app=hubble-ui
kubectl get pods -n kube-system -l k8s-app=hubble-relay

# Use Cilium CLI
cilium status
```

## Usage Examples

### Monitor Network Flows with Hubble

```bash
# Watch all flows
cilium observe

# Watch specific pod
cilium observe --pod default/my-app

# Watch with DNS information
cilium observe --verdict FORWARDED --type l7

# Monitor policy enforcement
cilium observe --verdict DROPPED
```

### Check Service Routing

```bash
# View service map
cilium service list

# Check BPF loadbalancing
cilium bpf lb list

# View endpoint information
cilium endpoint list
```

### Troubleshoot Connectivity

```bash
# Test connectivity between pods
cilium connectivity test

# Check network policies
kubectl get ciliumnetworkpolicy

# View policy logs
cilium observe --verdict DROPPED --since 5m
```

## Configuration Changes

### Enable kube-proxy (After Installation)

If you installed with kube-proxy replacement enabled and want to re-enable it:

```bash
# 1. Update .env
CILIUM_KUBE_PROXY_REPLACEMENT=false

# 2. Reinstall Cilium
./scripts/k8s-components.sh --cni-cilium

# Note: This will re-add kube-proxy to the cluster
```

### Disable Hubble UI (After Installation)

```bash
# 1. Update .env
CILIUM_HUBBLE_ENABLED=false

# 2. Reinstall Cilium
./scripts/k8s-components.sh --cni-cilium

# 3. Clean up Hubble resources
kubectl delete deployment hubble-ui -n kube-system
kubectl delete deployment hubble-relay -n kube-system
```

## Performance Comparison

### kube-proxy (IPVS Mode)
- Latency: ~1-2ms
- Memory: ~100-200MB
- CPU: Low-Medium
- Scalability: Good up to 5000 Services

### Cilium BPF Replacement
- Latency: ~0.1-0.5ms (50-80% improvement)
- Memory: ~50-100MB (Cilium agent only)
- CPU: Low
- Scalability: Excellent (10,000+ Services)

## Troubleshooting

### Cilium Pods Not Starting

```bash
# Check pod logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=50

# Check eBPF support
uname -r
bpftool feature

# Verify kernel modules
lsmod | grep -E "bpf|xt_socket"
```

### Hubble UI Not Accessible

```bash
# Check Hubble pods
kubectl get pods -n kube-system -l k8s-app=hubble-ui

# Verify service
kubectl get svc -n kube-system hubble-ui

# Port-forward manually
kubectl port-forward -n kube-system svc/hubble-ui 8080:80
```

### kube-proxy Still Running After Replacement

```bash
# Force delete kube-proxy
kubectl delete daemonset kube-proxy -n kube-system
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --force --grace-period=0

# Verify BPF programs
cilium bpf lb list
```

## Next Steps

1. **Test network policies:**
   ```bash
   kubectl apply -f docs/examples/network-policy.yaml
   ```

2. **Install MetalLB for LoadBalancer Services:**
   ```bash
   ./scripts/k8s-components.sh --with-metallb
   ```

3. **Monitor with Hubble:**
   ```bash
   kubectl port-forward -n kube-system svc/hubble-ui 8080:80
   ```

4. **Install Istio with Envoy Gateway:**
   ```bash
   ./scripts/istio-install.sh
   ```

## References

- [Cilium Documentation](https://cilium.io/)
- [Hubble Documentation](https://docs.cilium.io/en/stable/observability/hubble/)
- [kube-proxy Replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [eBPF Overview](https://ebpf.io/)
