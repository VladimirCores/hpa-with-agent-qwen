# Talos Kubernetes Cluster with HPA Study

A Vagrant-based Talos Linux Kubernetes cluster for studying Horizontal Pod Autoscaling (HPA) with Cilium CNI and kube-proxy replacement.

## Quick Start

### Prerequisites

- **Vagrant** installed
- **libvirt** installed and running (`systemctl status libvirtd`)
- **vagrant-libvirt** plugin: `vagrant plugin install vagrant-libvirt`
- **talosctl** CLI for cluster management
- **kubectl** CLI for Kubernetes management
- **helm** for component installation

### Step 1: Configure Environment

```bash
# Copy example environment file
cp .env.example .env

# (Optional) Edit .env to customize settings
```

### Step 2: Start VMs

```bash
# Start all VMs
./scripts/vms-startup.sh
```

**Wait time:** ~3-5 minutes (raw image mode with CoW overlays)

### Step 3: Bootstrap Talos Cluster

```bash
# Bootstrap Talos and Kubernetes
./scripts/talos-bootstrap.sh
```

**Wait time:** ~2-3 minutes

### Step 4: Install Cilium CNI

```bash
# Install Cilium with kube-proxy replacement (default)
./scripts/k8s-components.sh

# Or install with metrics-server for HPA
./scripts/k8s-components.sh -m
```

**What this does:**
- Installs Cilium CNI (eBPF-based networking)
- Enables kube-proxy replacement (BPF-based service routing)
- Optionally installs metrics-server for HPA

**Wait time:** ~2-3 minutes

### Step 5: Verify Cluster

```bash
# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -A

# Check Cilium status
cilium status

# Test metrics (if installed)
kubectl top nodes
```

## Current Cluster Status

| Component | Status | Version |
|-----------|--------|---------|
| **Talos** | ✅ Ready | v1.12.6 |
| **Kubernetes** | ✅ Ready | v1.35.2 |
| **CNI** | ✅ Cilium | v1.19.1 |
| **kube-proxy** | ✅ Replaced | BPF-based |
| **metrics-server** | Optional | - |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Talos Kubernetes Cluster                  │
│  Network: 10.0.0.0/24 (NAT)                                  │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Master    │  │  Worker-1   │  │  Worker-2   │         │
│  │ 10.0.0.10   │  │ 10.0.0.11   │  │ 10.0.0.12   │         │
│  │ 4 CPU/4GB   │  │ 1 CPU/2GB   │  │ 1 CPU/2GB   │         │
│  │ etcd, API   │  │ kubelet     │  │ kubelet     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                              │
│  CNI: Cilium (eBPF)                                          │
│  kube-proxy: Replaced with BPF                               │
└─────────────────────────────────────────────────────────────┘
```

## CNI Options

### Cilium (Default)

```bash
# Install Cilium with kube-proxy replacement
./scripts/k8s-components.sh

# Check status
cilium status
```

**Features:**
- eBPF-based networking
- kube-proxy replacement
- Network policies
- Hubble observability (optional)

### Flannel (Alternative)

```bash
# Install Flannel instead
./scripts/k8s-components.sh --cni-flannel
```

### Calico (Alternative)

```bash
# Install Calico instead
./scripts/k8s-components.sh --cni-calico
```

## HPA Study Setup

### With metrics-server (CPU/Memory HPA)

```bash
# Install metrics-server
./scripts/k8s-components.sh -m

# Deploy sample app
kubectl apply -f docs/examples/sample-app.yaml

# Create HPA
kubectl autoscale deployment sample-app --cpu-percent=50 --min=1 --max=10

# Generate load
kubectl run -i --tty load-generator --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://sample-app; done"

# Monitor
kubectl get hpa --watch
```

### Without metrics-server

Use custom metrics or external metrics providers. See `docs/06-HPA-Study-Guide.md`

## Management Commands

```bash
# Start cluster
./scripts/vms-startup.sh

# Stop cluster (preserves data)
./scripts/vms-cleanup.sh

# Full reset
./scripts/vms-cleanup.sh -n

# Re-bootstrap
./scripts/talos-bootstrap.sh
```

## Documentation

| Document | Description |
|----------|-------------|
| `docs/01-Network-setup.md` | Network configuration |
| `docs/02-Vagrant-VMs-provision.md` | VM provisioning |
| `docs/03-Talos-Configuration.md` | Talos bootstrap |
| `docs/04-Istio-Envoy-Gateway-Preview.md` | Istio installation |
| `docs/05-Cilium-Setup.md` | Cilium CNI guide |
| `docs/06-HPA-Study-Guide.md` | HPA examples and exercises |

## Troubleshooting

### Cilium Pods Not Ready

```bash
# Check Cilium status
cilium status

# Check logs
kubectl logs -n kube-system -l k8s-app=cilium

# Reinstall
cilium uninstall --wait
./scripts/k8s-components.sh
```

### Bootstrap Fails

```bash
# Reset nodes
talosctl reset --nodes 10.0.0.10,10.0.0.11,10.0.0.12 --graceful=false

# Re-bootstrap
./scripts/talos-bootstrap.sh
```

### Network Issues

```bash
# Check network
virsh -c qemu:///system net-info cluster-talos-net

# Check DHCP leases
virsh -c qemu:///system net-dhcp-leases cluster-talos-net

# Recreate network
./scripts/prepare-network.sh
```

## Resources

- [Talos Documentation](https://www.talos.dev/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA Study Guide](docs/06-HPA-Study-Guide.md)
