# Talos Kubernetes Cluster with HPA Study

## Project Overview

This project sets up a **Talos Linux Kubernetes cluster** using Vagrant and libvirt for studying **Horizontal Pod Autoscaling (HPA)** in a controlled environment. The cluster includes Istio service mesh with Envoy Gateway for advanced traffic management and observability.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Talos Kubernetes Cluster                  │
│  Network: 192.168.123.0/24 (NAT)                                  │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Master    │  │  Worker-1   │  │  Worker-2   │         │
│  │ 192.168.123.10   │  │ 192.168.123.20   │  │ 192.168.123.21   │         │
│  │ 4 CPU/6GB   │  │ 2 CPU/2GB   │  │ 2 CPU/2GB   │         │
│  │ etcd, API   │  │ kubelet     │  │ kubelet     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  Host (talosctl)  │
                    └───────────────────┘
```

### Key Technologies

| Component                 | Purpose                                       |
| ------------------------- | --------------------------------------------- |
| **Talos Linux**           | Immutable, minimal Kubernetes OS              |
| **Podman Registry**       | Local image caching for faster bootstrap      |
| **Vagrant + libvirt**     | VM provisioning and management                |
| **Kubernetes**            | Container orchestration                       |
| **Cilium CNI** (default)  | eBPF-based pod networking & observability     |
| **Hubble**                | Network observability (bundled with Cilium)   |
| **Infisical**             | Secret manager with web dashboard             |
| **Istio + Envoy Gateway** | Service mesh and API gateway                  |
| **MetalLB**               | LoadBalancer Services for bare-metal clusters |
| **metrics-server**        | Resource metrics for HPA                      |

> **Note:** Calico or Flannel can be used instead of Cilium via `./scripts/k8s-components.sh --cni-calico` or `--cni-flannel`

### Local Image Caching

The cluster uses a **Podman-based local registry** to cache all required images:

| Feature | Description |
|---------|-------------|
| **Cached Images** | 38+ images including Kubernetes components, CNI plugins, service mesh, and utilities |
| **Registry Mirrors** | Configured for docker.io, registry.k8s.io, quay.io, ghcr.io, gcr.io |
| **Benefits** | Faster bootstrap, offline operation, consistent versions |
| **Scripts** | `start-local-registry.sh`, `populate-local-registry.sh`, `verify-local-registry.sh` |

See `docs/16-Local-Registry-Guide.md` for complete details.

### Provisioning Modes

| Mode                    | Description                            | Speed    | Use Case                     |
| ----------------------- | -------------------------------------- | -------- | ---------------------------- |
| **Raw Image** (default) | Pre-built disk image with CoW overlays | ~2-3 min | Development, rapid iteration |
| **ISO Install**         | Traditional ISO-based installation     | ~5-7 min | Production-like setup        |
| **Vagrant Box**         | Pre-built Vagrant box                  | ~2-3 min | Reusable environments        |

---

## Directory Structure

```
with-agent-qwen/
├── .env.example          # Environment configuration template
├── Vagrantfile           # Vagrant VM definitions (libvirt provider)
├── .gitignore            # Git ignore rules
├── docs/                 # Documentation
│   ├── 01-Network-setup.md
│   ├── 02-Vagrant-VMs-provision.md
│   ├── 03-Talos-Configuration.md
│   └── 04-Istio-Envoy-Gateway-Preview.md
├── scripts/              # Automation scripts
│   ├── vms-startup/      # VM startup step scripts
│   ├── prepare-network.sh
│   ├── vms-startup.sh
│   ├── vms-cleanup.sh
│   ├── talos-bootstrap.sh
│   ├── k8s-components.sh
│   ├── infisical-install.sh  # Secret manager installation
│   ├── istio-install.sh
│   ├── create-talos-box.sh
│   └── set-boot-order.sh
├── .vagrant/raw-disks/   # VM disk overlays (git-ignored)
└── talos-cluster/        # Generated configs (git-ignored)
    ├── controlplane.yaml
    ├── worker.yaml
    ├── talosconfig
    ├── kubeconfig
    └── certs/
```

---

## Building and Running

### Prerequisites

- **Vagrant** installed
- **libvirt** installed and running (`systemctl status libvirtd`)
- **vagrant-libvirt** plugin: `vagrant plugin install vagrant-libvirt`
- **talosctl** CLI for cluster management
- **kubectl** CLI for Kubernetes management
- **helm** for Istio installation (optional)

### Quick Start

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env to customize (optional - defaults work)

# 2. Start local registry (recommended for faster bootstrap)
./scripts/start-local-registry.sh
./scripts/populate-local-registry.sh
./scripts/verify-local-registry.sh

# 3. Start the cluster (full automated setup)
./scripts/vms-startup.sh

# 4. Bootstrap Talos and Kubernetes
./scripts/talos-bootstrap.sh

# 5. Install Kubernetes components (CNI + metrics-server)
./scripts/k8s-components.sh

# 6. (Optional) Install Istio with Envoy Gateway
./scripts/istio-install.sh
```

**Note:** Step 2 (local registry) is highly recommended as it:
- Caches 38+ images locally for faster deployment
- Enables offline operation after initial population
- Ensures consistent image versions across deployments
- Configures Talos to use local registry mirrors automatically

### Script Commands

| Script                         | Description                     | Options                                                                                       |
| ------------------------------ | ------------------------------- | --------------------------------------------------------------------------------------------- |
| `./scripts/vms-startup.sh`     | Start all VMs                   | `-s` skip cleanup, `-f` force reset, `-v` verbose                                             |
| `./scripts/vms-cleanup.sh`     | Stop and remove VMs             | `-n` preserve network                                                                         |
| `./scripts/talos-bootstrap.sh` | Bootstrap Talos cluster         | `-n <name>` cluster name, `--no-merge` kubeconfig                                             |
| `./scripts/k8s-components.sh`  | Install CNI + metrics + MetalLB | `--cni-cilium`, `--cni-calico`, `--cni-flannel`, `--with-metrics`, `--with-metallb`, `--list` |
| `./scripts/istio-install.sh`   | Install Istio (preview)         | -                                                                                             |
| `./scripts/prepare-network.sh` | Setup libvirt network           | -                                                                                             |
| `./scripts/start-local-registry.sh` | Start Podman registry      | -                                                                                             |
| `./scripts/populate-local-registry.sh` | Cache cluster images    | -                                                                                             |
| `./scripts/verify-local-registry.sh` | Verify registry status    | -                                                                                             |

### Manual Vagrant Commands

```bash
# Start VMs
vagrant up --provider=libvirt

# Stop VMs
vagrant halt

# Destroy VMs
vagrant destroy -f

# Check status
vagrant status

# SSH (if supported)
vagrant ssh talos-master
```

### Verification Commands

```bash
# Check VMs
virsh -c qemu:///system list --all

# Check network
virsh -c qemu:///system net-info cluster-net
virsh -c qemu:///system net-dhcp-leases cluster-net

# Check Talos cluster
talosctl get members --nodes 192.168.123.10

# Check Kubernetes
kubectl get nodes
kubectl get pods -A
```

---

## Configuration

### Environment Variables (.env)

| Variable         | Default        | Description                      |
| ---------------- | -------------- | -------------------------------- |
| `NETWORK_NAME`   | cluster-net    | libvirt network name             |
| `MASTER_NAME`    | talos-master   | Master node name                 |
| `MASTER_IP`      | 192.168.123.10 | Master node IP                   |
| `MASTER_CPUS`    | 4              | Master CPU count                 |
| `MASTER_MEMORY`  | 6144           | Master memory (MB)               |
| `WORKER_COUNT`   | 2              | Number of workers                |
| `WORKER_IP_BASE` | 192.168.123.20 | First worker IP                  |
| `WORKER_CPUS`    | 1              | Worker CPU count                 |
| `WORKER_MEMORY`  | 2048           | Worker memory (MB)               |
| `CLUSTER_NAME`   | talos-cluster  | Cluster identifier               |
| `MAC_PREFIX`     | 52:54:00:00:00 | MAC address prefix               |
| `USE_RAW_IMAGE`  | true           | Use raw disk image (recommended) |
| `USE_BOX`        | false          | Use pre-built Vagrant box        |

### Network Configuration

| Setting      | Value                           |
| ------------ | ------------------------------- |
| Network CIDR | 192.168.123.0/24                |
| Gateway      | 192.168.123.1                   |
| DHCP Range   | 192.168.123.2 - 192.168.123.254 |
| Forward Mode | NAT                             |

### Static IP Reservations

| Node           | IP             | MAC                |
| -------------- | -------------- | ------------------ |
| talos-master   | 192.168.123.10 | `${MAC_PREFIX}:01` |
| talos-worker-1 | 192.168.123.20 | `${MAC_PREFIX}:0b` |
| talos-worker-2 | 192.168.123.21 | `${MAC_PREFIX}:0c` |

---

## Development Conventions

### Script Structure

All scripts follow a consistent pattern:

```bash
#!/bin/bash
set -euo pipefail

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
set -a
source "$PROJECT_ROOT/.env"
set +a

# Parse arguments with getopts
# Define functions
# Execute with verification
```

### Error Handling

- `set -euo pipefail` for strict error handling
- Explicit error messages with `ERROR:` prefix
- Graceful cleanup on failure
- Sudo authentication caching (15 min)

### Logging

- Step-based execution with clear headers
- Progress indicators (`✓`, `✗`, `...`)
- Summary sections at end of scripts

### Testing Practices

- Prerequisites checks before execution
- Idempotent operations (safe to re-run)
- Verification steps after critical operations
- Timeout handling for async operations

---

## Troubleshooting

### Common Issues

**Bootstrap fails with existing Talos state (Raw Image mode)**

```bash
# Bootstrap script auto-detects and resets if needed
./scripts/talos-bootstrap.sh

# Or manually reset
talosctl reset --nodes 192.168.123.10 --graceful=false
```

**Bootstrap fails with certificate errors (ISO mode, Talos v1.12.x)**

```bash
# Talos v1.12.x requires empty disks for maintenance mode
./scripts/vms-cleanup.sh  # Full cleanup (wipes disks)
./scripts/vms-startup.sh  # Fresh start
./scripts/talos-bootstrap.sh
```

**VMs fail to start**

```bash
# Check libvirtd
systemctl status libvirtd

# Check vagrant-libvirt plugin
vagrant plugin list | grep libvirt

# Check user permissions
sudo usermod -aG libvirt $USER  # Then log out/in
```

**Registry issues**

```bash
# Check registry container
podman ps | grep registry

# Verify cached images
./scripts/verify-local-registry.sh

# Re-populate if needed
./scripts/populate-local-registry.sh

# Check Talos mirror config
talosctl get machineconfig --nodes 192.168.123.10
```

**Network issues**

```bash
# Recreate network
./scripts/prepare-network.sh

# Check DHCP leases
virsh -c qemu:///system net-dhcp-leases cluster-net
```

**kubectl cannot connect**

```bash
# Regenerate kubeconfig
talosctl kubeconfig . --nodes 192.168.123.10 --force
```

**Raw image overlays not created**

```bash
# Ensure qemu-img is installed
qemu-img --version

# Manually create overlay directory
mkdir -p .vagrant/raw-disks

# Re-run startup with force reset
./scripts/vms-startup.sh -f
```

---

## Next Steps for HPA Study

1. **Install Kubernetes components (Cilium + metrics-server):**

   ```bash
   ./scripts/k8s-components.sh
   ```

2. **Install MetalLB LoadBalancer (optional - for external Services):**

   ```bash
   ./scripts/k8s-components.sh --with-metallb
   # Or install everything: --with-metrics --with-metallb

   # Verify MetalLB
   kubectl get pods -n metallb-system
   kubectl get ipaddresspools.metallb.io -n metallb-system
   ```

3. **Install Infisical Secret Manager (optional - for secret management):**

   ```bash
   ./scripts/infisical-install.sh
   # Access dashboard: kubectl port-forward svc/infisical-ui -n infisical 8081:80
   ```

4. **Deploy sample application:**

   ```bash
   kubectl apply -f docs/examples/sample-app.yaml
   ```

5. **Configure HPA:**

   ```bash
   kubectl autoscale deployment sample-app --cpu-percent=50 --min=1 --max=10
   ```

6. **Generate load and observe scaling:**

   ```bash
   kubectl run -i --tty load-generator --image=busybox --restart=Never -- \
     /bin/sh -c "while true; do wget -q -O- http://sample-app; done"
   ```

7. **Monitor with Hubble (Cilium observability):**

   ```bash
   kubectl port-forward -n kube-system svc/hubble-ui 8080:80
   # Then open http://localhost:8080
   ```

8. **Monitor with Istio (if installed):**
   ```bash
   kubectl port-forward -n istio-system svc/grafana 3000:3000
   ```

---

## Resources

- [Talos Documentation](https://www.talos.dev/)
- [Vagrant libvirt Provider](https://github.com/vagrant-libvirt/vagrant-libvirt)
- [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Cilium & Hubble](https://cilium.io/)
- [MetalLB LoadBalancer](https://metallb.universe.tf/)
- [Infisical Secret Manager](https://infisical.com/)
- [Istio Documentation](https://istio.io/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [Podman Registry](https://docs.podman.io/)
- [Local Registry Guide](docs/16-Local-Registry-Guide.md)

When asked to commit changes, do exactly that: stage all changes, write a descriptive conventional-commit message, and commit. Do NOT explore the codebase, debug VMs, or investigate other issues unless the user explicitly asks for it alongside the commit.

When user says 'continue from last session' or 'resume previous work', first read memory files from ~/.qwen/memory/ or the project root, and if not found, ask the user for the exact file path rather than guessing multiple incorrect paths.

Before running any shell command that might modify the system (especially libvirt, vagrant, sudo, qemu-img, virsh), first check the current state with read-only commands to avoid accidental deletions or conflicting state assumptions.

When the user provides a task that involves fixing scripts or infrastructure, start with a minimal, targeted fix rather than restructuring the entire codebase or moving code to external files.

If you cannot process an image or file the user provides, clearly state your limitation and ask for a text alternative (typed URL, description, or pasted content) rather than repeatedly failing.