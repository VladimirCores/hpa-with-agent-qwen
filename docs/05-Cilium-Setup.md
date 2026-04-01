# Cilium CNI Setup with Talos Linux

This document describes how to install Cilium CNI with kube-proxy replacement on a Talos Linux cluster.

## Overview

Cilium is an eBPF-based CNI that provides:
- **High-performance networking** using eBPF
- **kube-proxy replacement** for better scalability
- **Network policies** for security
- **Hubble** for observability (optional)
- **Service mesh** capabilities (optional)

## Quick Start

```bash
# 1. Start VMs
./scripts/vms-startup.sh

# 2. Bootstrap cluster
./scripts/talos-bootstrap.sh

# 3. Install Cilium with kube-proxy replacement
./scripts/k8s-components.sh --cni-cilium

# 4. (Optional) Remove metrics-server if not needed
kubectl delete deployment metrics-server -n kube-system
```

## Installation Steps

### Step 1: Bootstrap Talos Cluster

First, ensure your Talos cluster is running:

```bash
# Start VMs
./scripts/vms-startup.sh

# Bootstrap Talos
./scripts/talos-bootstrap.sh

# Verify cluster is ready
kubectl --kubeconfig talos-cluster/kubeconfig get nodes
```

### Step 2: Install Cilium

The `k8s-components.sh` script handles Cilium installation:

```bash
./scripts/k8s-components.sh --cni-cilium
```

This script:
1. Installs Cilium CLI
2. Deploys Cilium with kube-proxy replacement enabled
3. Configures BPF masquerading
4. Waits for Cilium to be ready

### Step 3: Verify Installation

```bash
# Check Cilium status
cilium status --kubeconfig talos-cluster/kubeconfig

# Check Cilium pods
kubectl --kubeconfig talos-cluster/kubeconfig get pods -n kube-system -l k8s-app=cilium

# Check nodes
kubectl --kubeconfig talos-cluster/kubeconfig get nodes
```

Expected output:
```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:         OK
 \__/¯¯\__/    Operator:       OK
 /¯¯\__/¯¯\    Envoy:          OK
 \__/¯¯\__/    Hubble Relay:   disabled
    \__/       ClusterMesh:    disabled
```

## Configuration

### Default Settings

The installation uses these defaults:

| Setting | Value | Description |
|---------|-------|-------------|
| `kubeProxyReplacement` | `true` | Replace kube-proxy with eBPF |
| `bpf.masquerade` | `true` | Enable BPF-based NAT |
| `ipam.mode` | `kubernetes` | Use Kubernetes IPAM |
| `securityContext.privileged` | `true` | Required for Talos |
| `hubble.enabled` | `false` | Disabled by default |

### Enable Hubble (Optional)

For observability, enable Hubble:

```bash
cilium hubble enable --kubeconfig talos-cluster/kubeconfig
cilium hubble ui --kubeconfig talos-cluster/kubeconfig
```

Access the UI at `http://localhost:12000`

## kube-proxy Replacement

Cilium replaces kube-proxy using eBPF. This provides:

- **Better performance**: Direct packet forwarding
- **Lower latency**: No iptables overhead
- **Better scalability**: Handles more services/endpoints

### Verify kube-proxy is Replaced

```bash
# Check kube-proxy pods (should be gone)
kubectl --kubeconfig talos-cluster/kubeconfig get pods -n kube-system -l k8s-app=kube-proxy

# Check Cilium config
cilium config view --kubeconfig talos-cluster/kubeconfig | grep kube-proxy-replacement
```

## Troubleshooting

### Cilium Pods Not Ready

```bash
# Check pod status
kubectl --kubeconfig talos-cluster/kubeconfig get pods -n kube-system -l k8s-app=cilium

# Check logs
kubectl --kubeconfig talos-cluster/kubeconfig logs -n kube-system -l k8s-app=cilium

# Check events
kubectl --kubeconfig talos-cluster/kubeconfig describe pods -n kube-system -l k8s-app=cilium
```

### Network Connectivity Issues

```bash
# Test DNS
kubectl --kubeconfig talos-cluster/kubeconfig run -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default

# Test connectivity
kubectl --kubeconfig talos-cluster/kubeconfig run -it --rm test --image=busybox:1.36 --restart=Never -- wget -qO- http://kubernetes.default
```

### Reinstall Cilium

```bash
# Uninstall
cilium uninstall --kubeconfig talos-cluster/kubeconfig --wait

# Reinstall
./scripts/k8s-components.sh --cni-cilium
```

## Switching from Flannel

If you have Flannel installed and want to switch to Cilium:

```bash
# Remove Flannel
kubectl --kubeconfig talos-cluster/kubeconfig delete -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# Install Cilium
./scripts/k8s-components.sh --cni-cilium
```

## Resources

- [Cilium Documentation](https://docs.cilium.io/)
- [Cilium on Talos](https://www.talos.dev/v1.12/kubernetes-guides/configuration/cilium/)
- [Hubble Observability](https://docs.cilium.io/en/stable/observability/)
