# Cilium CNI Setup with Talos Linux

This document describes how to enable Cilium CNI support in the Talos cluster.

## Overview

Cilium requires specific configuration when running on Talos Linux due to the operating system's unique design:

1. **Disable Default CNI**: Talos includes Flannel by default, which must be disabled
2. **Kube-proxy Replacement**: Cilium replaces kube-proxy for better performance
3. **SYS_MODULE Capability**: Must be dropped (Talos doesn't allow kernel module loading)
4. **Cgroup Configuration**: Must reuse Talos cgroupv2 mount
5. **API Server Connectivity**: Use KubePrism proxy (localhost:7445)

## Quick Start (Recommended)

```bash
# 1. Clean up any existing cluster
./scripts/vms-cleanup.sh -n

# 2. Start VMs (Cilium-ready configs applied automatically)
./scripts/vms-startup.sh

# 3. Bootstrap cluster
./scripts/talos-bootstrap.sh

# 4. Install Cilium with Talos-specific settings
./scripts/k8s-components.sh --cni-cilium
```

## Configuration Requirements

### Talos Machine Config

The following settings are required in `controlplane.yaml` and `worker.yaml`:

```yaml
machine:
  network:
    disableDefaultCNI: true  # Disable Flannel
  kubelet:
    defaultRuntimeSeccompProfileEnabled: false  # Allow Cilium capabilities
  features:
    kubePrism:
      enabled: true  # Local proxy on port 7445
      port: 7445
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:reader
      allowedKubernetesNamespaces:
        - kube-system
```

### Cilium Helm Values for Talos

```yaml
kubeProxyReplacement: true
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
k8sServiceHost: localhost
k8sServicePort: 7445  # KubePrism port
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    # Note: SYS_MODULE intentionally omitted for Talos
```

## Manual Setup

If automatic setup fails, you can apply configs manually:

```bash
# 1. Start VMs and wait for maintenance mode
./scripts/vms-startup.sh

# 2. IMMEDIATELY apply configs (within 30 seconds)
talosctl apply-config --nodes 10.0.0.10 \
  --file talos-cluster/controlplane.yaml \
  --insecure

talosctl apply-config --nodes 10.0.0.11 \
  --file talos-cluster/worker.yaml \
  --insecure

talosctl apply-config --nodes 10.0.0.12 \
  --file talos-cluster/worker.yaml \
  --insecure

# 3. Wait for install and reboot
# 4. Bootstrap
./scripts/talos-bootstrap.sh

# 5. Install Cilium
helm install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set bpf.masquerade=true \
  --set routingMode=native \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

## Verification

```bash
# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Cilium status
cilium status

# Check Hubble
kubectl get pods -n kube-system -l k8s-app=hubble-relay

# Access Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8080:80
# Open http://localhost:8080
```

## Troubleshooting

### Cilium Pods CrashLoopBackOff

**Error:** `unable to apply caps: can't apply capabilities: operation not permitted`

**Cause:** Talos security settings don't allow required capabilities.

**Solution:** The configs must be applied BEFORE Talos installs to disk. If Talos already installed with default settings, you must:

1. Delete VM disks: `virsh vol-delete --pool talos-pool <disk-name>`
2. Restart VMs: `./scripts/vms-startup.sh`
3. Apply configs immediately (within 30 seconds)

### Config Apply Too Late

If you see `PermissionDenied` when applying configs, Talos has already installed to disk with default settings.

**Solution:** Delete disks and restart:

```bash
virsh -c qemu:///system vol-delete --pool talos-pool with-agent-qwen_talos-master-vda.qcow2
virsh -c qemu:///system vol-delete --pool talos-pool with-agent-qwen_talos-worker-1-vda.qcow2
virsh -c qemu:///system vol-delete --pool talos-pool with-agent-qwen_talos-worker-2-vda.qcow2
./scripts/vms-startup.sh
```

## Fallback: Flannel CNI

If Cilium doesn't work, Flannel is available as a fallback:

```bash
# After bootstrap, install Flannel instead
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Flannel works with default Talos security settings and doesn't require special configuration.

## Configuration Files

### controlplane.yaml (Cilium-ready settings)

```yaml
machine:
  kubelet:
    defaultRuntimeSeccompProfileEnabled: false  # Required for Cilium
  features:
    kubernetesTalosAPIAccess:
      enabled: true  # Required for Cilium
      allowedRoles:
        - os:reader
      allowedKubernetesNamespaces:
        - kube-system
```

### worker.yaml (Cilium-ready settings)

```yaml
machine:
  kubelet:
    defaultRuntimeSeccompProfileEnabled: false  # Required for Cilium
```

## Resources

- [Cilium Documentation](https://docs.cilium.io/)
- [Cilium on Talos](https://www.talos.dev/v1.12/kubernetes-guides/configuration/cilium/)
- [Hubble Observability](https://docs.cilium.io/en/stable/observability/)
