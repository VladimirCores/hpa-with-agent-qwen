# Talos Kubernetes Cluster with HPA Study

A Vagrant-based Talos Linux Kubernetes cluster for studying Horizontal Pod Autoscaling (HPA) with optional Cilium CNI and Infisical secret management.

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
# Common settings:
# - MASTER_CPUS, MASTER_MEMORY - Master node resources
# - WORKER_COUNT - Number of worker nodes
# - TALOS_IMAGE_URL - Talos version to use
```

### Step 2: Start VMs

```bash
# Start all VMs (automatically handles network, storage, and VM creation)
./scripts/vms-startup.sh
```

**What this does:**
- Creates libvirt network (10.0.0.0/24)
- Creates storage pool for VM disks
- Downloads Talos ISO if not present
- Creates VMs with empty disks
- Boots VMs from ISO (Talos installs to disk)
- VMs reboot from disk after installation

**Wait time:** ~5-7 minutes for first run

### Step 3: Bootstrap Talos Cluster

```bash
# Bootstrap Talos and Kubernetes
./scripts/talos-bootstrap.sh
```

**What this does:**
- Generates cluster secrets
- Generates machine configurations
- Waits for all nodes to be ready
- Bootstraps Kubernetes control plane
- Applies configurations to all nodes
- Fetches kubeconfig

**Wait time:** ~3-5 minutes

### Step 4: Install Kubernetes Components

```bash
# Install CNI and metrics-server (default: Flannel)
./scripts/k8s-components.sh

# Or install Cilium instead:
# ./scripts/k8s-components.sh --cni-cilium
```

**What this does:**
- Installs CNI (Flannel or Cilium)
- Installs metrics-server (required for HPA)
- Waits for all components to be ready

**Wait time:** ~2-3 minutes

### Step 5: Verify Cluster

```bash
# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -A

# Test HPA (metrics-server)
kubectl top nodes
```

**Expected output:**
```
NAME             STATUS   ROLES           AGE   VERSION
talos-master     Ready    control-plane   10m   v1.35.2
talos-worker-1   Ready    <none>          10m   v1.35.2
talos-worker-2   Ready    <none>          10m   v1.35.2
```

## Optional Components

### Infisical Secret Manager

```bash
# Install Infisical (secret manager with web dashboard)
./scripts/infisical-install.sh

# Access dashboard
kubectl port-forward svc/infisical-ui -n infisical 8081:80
# Open http://localhost:8081
```

### Istio with Envoy Gateway

```bash
# Install Istio (preview)
./scripts/istio-install.sh
```

## Cluster Access

### Using talosctl

```bash
# Talos cluster info
talosctl get members --nodes 10.0.0.10

# Talos services
talosctl services --nodes 10.0.0.10
```

### Using kubectl

```bash
# Kubeconfig location
export KUBECONFIG=/home/cores/.kube/config

# Or use explicit kubeconfig
kubectl --kubeconfig=talos-cluster/kubeconfig get nodes
```

## Management Commands

### Start Cluster

```bash
# After host reboot, start VMs
./scripts/vms-startup.sh
```

### Stop Cluster

```bash
# Stop VMs (preserves data)
./scripts/vms-cleanup.sh
```

### Full Reset

```bash
# Destroy everything (network, storage, VMs)
./scripts/vms-cleanup.sh -n
```

### Re-bootstrap

```bash
# Reset Talos cluster state (keeps VMs)
talosctl reset --nodes 10.0.0.10 --graceful=false
talosctl reset --nodes 10.0.0.11 --graceful=false
talosctl reset --nodes 10.0.0.12 --graceful=false

# Re-bootstrap
./scripts/talos-bootstrap.sh
```

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
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  Host (talosctl)  │
                    └───────────────────┘
```

## Default Configuration

| Component | Setting | Value |
|-----------|---------|-------|
| **Network** | CIDR | 10.0.0.0/24 |
| | Gateway | 10.0.0.1 |
| **Master** | IP | 10.0.0.10 |
| | CPUs | 4 |
| | Memory | 4096 MB |
| | Disk | 50 GB |
| **Workers** | Count | 2 |
| | IPs | 10.0.0.11, 10.0.0.12 |
| | CPUs | 1 each |
| | Memory | 2048 MB each |
| | Disk | 20 GB each |
| **CNI** | Default | Flannel |
| | Alternative | Cilium (--cni-cilium) |

## Troubleshooting

### VMs Not Starting

```bash
# Check libvirtd
systemctl status libvirtd

# Check vagrant-libvirt plugin
vagrant plugin list | grep libvirt

# Check user permissions
sudo usermod -aG libvirt $USER  # Then log out/in
```

### Talos API Not Accessible

```bash
# Check VM status
virsh -c qemu:///system list | grep talos

# Check DHCP leases
virsh -c qemu:///system net-dhcp-leases cluster-talos-net

# Check Talos in maintenance mode
talosctl version --nodes 10.0.0.10 --insecure
```

### kubectl Cannot Connect

```bash
# Regenerate kubeconfig
talosctl kubeconfig . --nodes 10.0.0.10 --force

# Or merge with existing
talosctl kubeconfig --merge --nodes 10.0.0.10
```

### CNI Pods Not Ready

```bash
# Check CNI pods
kubectl get pods -n kube-system -l app=flannel

# Or for Cilium
kubectl get pods -n kube-system -l k8s-app=cilium

# Reinstall CNI
./scripts/k8s-components.sh --cni-flannel
# or
./scripts/k8s-components.sh --cni-cilium
```

### Bootstrap Fails

```bash
# Reset nodes
talosctl reset --nodes 10.0.0.10 --graceful=false
talosctl reset --nodes 10.0.0.11 --graceful=false
talosctl reset --nodes 10.0.0.12 --graceful=false

# Re-bootstrap
./scripts/talos-bootstrap.sh
```

## HPA Study Setup

After cluster is ready:

```bash
# 1. Deploy sample application
kubectl apply -f docs/examples/sample-app.yaml

# 2. Configure HPA
kubectl autoscale deployment sample-app --cpu-percent=50 --min=1 --max=10

# 3. Generate load
kubectl run -i --tty load-generator --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://sample-app; done"

# 4. Monitor scaling
kubectl get hpa --watch
kubectl get pods --watch
```

## Documentation

- `docs/01-Network-setup.md` - Network configuration
- `docs/02-Vagrant-VMs-provision.md` - VM provisioning
- `docs/03-Talos-Configuration.md` - Talos bootstrap and K8s components
- `docs/04-Istio-Envoy-Gateway-Preview.md` - Istio installation
- `docs/05-Cilium-Setup.md` - Cilium CNI configuration

## Resources

- [Talos Documentation](https://www.talos.dev/)
- [Vagrant libvirt Provider](https://github.com/vagrant-libvirt/vagrant-libvirt)
- [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Infisical Documentation](https://infisical.com/docs)
