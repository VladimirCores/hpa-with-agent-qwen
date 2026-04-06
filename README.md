# Talos Kubernetes Cluster with HPA Study

A Vagrant-based Talos Linux Kubernetes cluster for studying Horizontal Pod Autoscaling (HPA) with advanced networking and observability.

## Quick Start

### Prerequisites

- **Vagrant** installed
- **libvirt** installed and running (`systemctl status libvirtd`)
- **vagrant-libvirt** plugin: `vagrant plugin install vagrant-libvirt`
- **talosctl** CLI for cluster management
- **kubectl** CLI for Kubernetes management
- **helm** for component installation
- **User in libvirt group**: `sudo usermod -aG libvirt $USER` (then log out/in)

### Step 1: Configure Environment

```bash
# Copy and customize environment file
cp .env.example .env

# Optional: Set sudo password for non-interactive startup
# (prevents sudo prompts during startup.sh)
# echo "SUDO_PASSWORD=your_password" >> .env
```

### Step 2: Start Cluster

```bash
# Start all VMs (step-by-step with verification)
./startup.sh

# Options:
#   -s  Skip cleanup (don't stop existing VMs)
#   -f  Force reset (destroy VMs and disks)
```

**Wait time:** ~8-12 minutes (ISO boot + Talos install to disk)

### Step 3: Bootstrap Talos Cluster

```bash
# Bootstrap Talos and Kubernetes
./bootstrap.sh
```

**Wait time:** ~3-5 minutes

### Step 4: Install Cilium CNI

```bash
# Install Cilium with kube-proxy replacement
./scripts/k8s-components.sh
```

**Wait time:** ~2-3 minutes

### Cleanup

```bash
# Stop VMs (preserve network and storage)
./cleanup.sh

# Full cleanup (destroy network and storage)
./cleanup.sh -f
```

### Step 5: Verify Cluster

```bash
# Check nodes
KUBECONFIG=talos-cluster/kubeconfig kubectl get nodes

# Check system pods
KUBECONFIG=talos-cluster/kubeconfig kubectl get pods -A

# Check Cilium status
KUBECONFIG=talos-cluster/kubeconfig cilium status
```

### Step 6: Access Kubernetes Dashboard

The dashboard is automatically installed during bootstrap and exposed via NodePort.

```bash
# Open in browser (accept certificate warning)
https://192.168.123.10:30443

# Or access via any worker node
https://192.168.123.20:30443
https://192.168.123.21:30443

# Login with admin token
cat talos-cluster/dashboard-admin-token.txt
```

## Current Cluster Status

| Component | Status | Version |
|-----------|--------|---------|
| **Talos** | ✅ Ready | v1.12.6 |
| **Kubernetes** | ✅ Ready | v1.35.2 |
| **CNI** | 🔲 Cilium/Flannel/Calico | Configurable |
| **metrics-server** | Optional | v0.7.1 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Talos Kubernetes Cluster                  │
│  Network: 192.168.123.0/24 (NAT)                             │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Master    │  │  Worker-1   │  │  Worker-2   │         │
│  │ 192.168.123.10│ │ 192.168.123.20│ │ 192.168.123.21│     │
│  │ 4 CPU/6GB   │  │ 2 CPU/2GB   │  │ 2 CPU/2GB   │         │
│  │ etcd, API   │  │ kubelet     │  │ kubelet     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  Host (talosctl)  │
                    └───────────────────┘
```

### VM Boot Flow

```
1. VM boots from disk (empty)
2. Falls back to ISO (CDROM)
3. Talos auto-installs to disk from ISO
4. VM auto-reboots
5. Boots from disk (installed Talos)
6. Ready for bootstrap
```

### Persistent Disk

VMs use **disk-first boot order** (`hd → cdrom`):
- After initial ISO install, VMs boot from installed Talos on disk
- Disks persist across reboots
- No need to re-install on subsequent startups

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK_NAME` | cluster-net | libvirt network name |
| `MASTER_IP` | 192.168.123.10 | Master node IP |
| `MASTER_CPUS` | 4 | Master CPU count |
| `MASTER_MEMORY` | 6144 | Master memory (MB) |
| `WORKER_COUNT` | 2 | Number of workers |
| `WORKER_IP_BASE` | 192.168.123.20 | First worker IP |
| `WORKER_CPUS` | 2 | Worker CPU count |
| `WORKER_MEMORY` | 2048 | Worker memory (MB) |
| `FORWARD_MODE` | nat | Network mode (nat or bridge) |
| `LIBVIRT_URI` | qemu:///system | Libvirt connection URI |
| `SUDO_PASSWORD` | (empty) | Sudo password for non-interactive startup |

### Network Configuration

| Setting | Value |
|---------|-------|
| Network CIDR | 192.168.123.0/24 |
| Gateway | 192.168.123.1 |
| DHCP Range | 192.168.123.2 - 192.168.123.254 |
| Forward Mode | NAT |

### Static IP Reservations

| Node | IP | MAC |
|------|-----|-----|
| talos-master | 192.168.123.10 | `${MAC_PREFIX}:01` |
| talos-worker-1 | 192.168.123.20 | `${MAC_PREFIX}:0b` |
| talos-worker-2 | 192.168.123.21 | `${MAC_PREFIX}:0c` |

## CNI Options

### Cilium (Recommended)

```bash
# Install Cilium with kube-proxy replacement
./scripts/k8s-components.sh --cni-cilium
```

**Features:**
- eBPF-based networking
- kube-proxy replacement
- Network policies
- Hubble observability

### Flannel

```bash
# Install Flannel
./scripts/k8s-components.sh --cni-flannel
```

### Calico

```bash
# Install Calico
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

## Management Commands

```bash
# Start cluster
./startup.sh

# Bootstrap Talos
./bootstrap.sh

# Stop cluster (preserves data)
./cleanup.sh

# Full reset
./cleanup.sh -f

# Check VM status
virsh -c qemu:///system list | grep talos

# Check DHCP leases
virsh -c qemu:///system net-dhcp-leases cluster-net
```

## Startup Script Steps

The `startup.sh` script runs 8 steps with verification:

| Step | Description | Duration |
|------|-------------|----------|
| 1 | Check prerequisites | ~5s |
| 2 | Prepare Talos image | ~5s |
| 3 | Create storage pool | ~5s |
| 4 | Setup network | ~10s |
| 5 | Cleanup existing VMs | ~15s |
| 6 | Start VMs | ~60s |
| 7 | Skip UEFI (BIOS boot) | ~2s |
| 8 | Wait for Talos boot | ~5-8 min |

Each step logs detailed progress with timestamps. See `/tmp/vms-startup.log` for full logs.

## Bootstrap Script Steps

The `bootstrap.sh` script runs 10 steps:

| Step | Description | Duration |
|------|-------------|----------|
| 1 | Check prerequisites | ~5s |
| 2 | Generate secrets | ~2s |
| 3 | Generate configs | ~5s |
| 4 | Wait for nodes | ~2min |
| 5 | Bootstrap cluster | ~30s |
| 6 | Apply configs | ~30s |
| 7 | Verify bootstrap (health checks) | ~2min |
| 8 | Configure kubectl | ~10s |
| 9 | Install Kubernetes Dashboard | ~1min |
| 10 | Cluster verification | ~15s |

### Dashboard Access

After bootstrap completes, the Kubernetes Dashboard is accessible at:

```
URL: https://192.168.123.10:30443
Token: talos-cluster/dashboard-admin-token.txt
```

The dashboard provides web-based cluster monitoring, pod management, and resource visualization.

## Documentation

| Document | Description |
|----------|-------------|
| `docs/01-Network-setup.md` | Network configuration |
| `docs/02-Vagrant-VMs-provision.md` | VM provisioning |
| `docs/03-Talos-Configuration.md` | Talos bootstrap |
| `docs/04-Istio-Envoy-Gateway-Preview.md` | Istio installation |
| `docs/05-Cilium-Setup.md` | Cilium CNI guide |
| `docs/06-HPA-Study-Guide.md` | HPA examples and exercises |
| `docs/07-User-Session-Mode.md` | User session mode |
| `docs/08-Kubernetes-Dashboard.md` | Dashboard setup and access |

## Troubleshooting

### VMs Won't Start

```bash
# Check libvirtd
systemctl status libvirtd

# Check storage pool
virsh -c qemu:///system pool-info talos-pool

# Check network
virsh -c qemu:///system net-info cluster-net
```

### Bootstrap Fails

```bash
# Check if nodes are in maintenance mode
talosctl version --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure

# Reset nodes (wipes disks)
talosctl reset --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure --graceful=false --wait=false

# Full cleanup and restart
./cleanup.sh -f
./startup.sh
./bootstrap.sh
```

### Talos Not Accessible After Boot

```bash
# Check VM IPs
virsh -c qemu:///system net-dhcp-leases cluster-net

# Check Talos status
talosctl version --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure

# Check cluster members
talosctl get members --nodes 192.168.123.10 --endpoints 192.168.123.10
```

### Network Issues

```bash
# Recreate network
./scripts/prepare-network.sh

# Check DHCP
virsh -c qemu:///system net-dhcp-leases cluster-net
```

### Sudo Prompts During Startup

Set `SUDO_PASSWORD` in `.env` to avoid interactive sudo prompts:

```bash
echo "SUDO_PASSWORD=your_password" >> .env
```

### Dashboard Access Issues

```bash
# Check dashboard pods
kubectl get pods -n kubernetes-dashboard

# Check dashboard service
kubectl get svc -n kubernetes-dashboard

# Verify NodePort
kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}'

# Regenerate admin token
kubectl -n kubernetes-dashboard create token admin-user > talos-cluster/dashboard-admin-token.txt

# Test connectivity
curl -k https://192.168.123.10:30443
```

## Sudo Password Caching

When `SUDO_PASSWORD` is set in `.env`, all scripts use it for sudo commands automatically:

```bash
# Without SUDO_PASSWORD: prompts for password
./startup.sh

# With SUDO_PASSWORD: non-interactive
# (set in .env: SUDO_PASSWORD=your_password)
./startup.sh
```

**Security note:** Never commit `.env` with real password to version control.

## Resources

- [Talos Documentation](https://www.talos.dev/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA Study Guide](docs/06-HPA-Study-Guide.md)
