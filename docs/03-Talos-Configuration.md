# Talos Cluster Configuration and Kubernetes Bootstrap

This document describes how to generate machine configurations, bootstrap the Talos cluster, and install general Kubernetes components.

## Overview

After VMs are running, this step covers:

1. **Generate Machine Configurations** - Create Talos configuration files
2. **Bootstrap Talos Cluster** - Initialize control plane and join workers
3. **Install Kubernetes Components** - CNI, metrics-server, and essential addons
4. **Verify Cluster** - Ensure everything is working correctly

### Provisioning Mode Differences

| Mode | Bootstrap Approach | Notes |
|------|-------------------|-------|
| **Raw Image** | VMs boot with Talos pre-installed | Requires `talosctl reset` before re-bootstrap |
| **ISO Install** | VMs boot to maintenance mode | Clean install on empty disk |

> **ℹ️ Talos v1.12.x Notes (ISO Mode)**
>
> Talos v1.12.x requires **empty disks** to boot into maintenance mode for bootstrap.
>
> **Workflow (ISO Mode)**:
>
> ```bash
> # 1. Full cleanup (wipes all disks)
> ./scripts/vms-cleanup.sh
>
> # 2. Start VMs (disks are empty, boots to maintenance mode)
> ./scripts/vms-startup.sh
>
> # 3. Bootstrap (generates secrets, configs, applies config)
> ./scripts/talos-bootstrap.sh
> ```

> **ℹ️ Raw Image Mode**
>
> VMs boot directly into Talos from pre-installed disk image.
>
> **Workflow (Raw Image Mode)**:
>
> ```bash
> # 1. Start VMs (boots from raw image)
> ./scripts/vms-startup.sh
>
> # 2. Bootstrap (automatically resets if needed)
> ./scripts/talos-bootstrap.sh
> ```
>
> The bootstrap script automatically detects if Talos state exists and performs reset if needed.

> **Verify maintenance mode**:
>
> ```bash
> talosctl get machineconfig --nodes 10.0.0.10 --insecure
> # Empty output or success = maintenance mode ✓
> # PermissionDenied = cluster mode (run cleanup or reset)
> ```

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Talos Cluster                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Master    │  │  Worker-1   │  │  Worker-2   │         │
│  │ 10.0.0.10   │  │ 10.0.0.11   │  │ 10.0.0.12   │         │
│  │  etcd       │  │  kubelet    │  │  kubelet    │         │
│  │  apiServer  │  │  kube-proxy │  │  kube-proxy │         │
│  │  scheduler  │  │             │  │             │         │
│  │  controller │  │             │  │             │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │    talosctl       │
                    │   (admin host)    │
                    └───────────────────┘
```

### Components Installed

| Component      | Version          | Purpose                 |
| -------------- | ---------------- | ----------------------- |
| Talos          | latest           | Kubernetes OS           |
| Kubernetes     | bundled by Talos | Container orchestration |
| Cilium CNI     | 1.16.0           | eBPF-based pod networking & observability |
| Hubble         | bundled          | Network observability (Cilium) |
| metrics-server | 0.7.1            | Resource metrics API    |
| kube-proxy     | bundled          | Service networking      |
| **Infisical**  | 0.60.0           | Secret manager with dashboard (optional) |

> **Note:** Istio with Envoy Gateway will be added in the next step using Helm.
> **Note:** Calico or Flannel can be used instead of Cilium: `./scripts/k8s-components.sh --cni-calico` or `--cni-flannel`
> **Note:** Install Infisical for secret management: `./scripts/infisical-install.sh`

## Prerequisites

- Talos cluster VMs running (see `02-Vagrant-VMs-provision.md`)
- `talosctl` installed on your host machine
- `kubectl` installed on your host machine
- Cluster accessible from your host network

### Install talosctl

```bash
# Download latest talosctl
curl -L -o talosctl https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-amd64
chmod +x talosctl
sudo mv talosctl /usr/local/bin/

# Verify installation
talosctl version
```

### Install kubectl

```bash
# Download latest kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Verify installation
kubectl version --client
```

## Configuration

### Environment Variables

The following variables from `.env` are used:

| Variable         | Default       | Description            |
| ---------------- | ------------- | ---------------------- |
| `CLUSTER_NAME`   | talos-cluster | Cluster identifier     |
| `MASTER_IP`      | 10.0.0.10     | Master node IP         |
| `WORKER_COUNT`   | 2             | Number of worker nodes |
| `WORKER_IP_BASE` | 10.0.0.11     | First worker IP        |

### Machine Configuration Types

Talos uses three configuration types:

| Type           | Role         | Description                                        |
| -------------- | ------------ | -------------------------------------------------- |
| `controlplane` | Master       | Runs control plane components                      |
| `init`         | First Master | Initializes the cluster (first control plane node) |
| `worker`       | Worker       | Runs only worker components                        |

## Usage

### Quick Start (Automated)

Bootstrap the entire cluster and install Kubernetes components:

```bash
# Bootstrap Talos
./scripts/talos-bootstrap.sh

# Install Kubernetes components (Cilium CNI + metrics-server)
./scripts/k8s-components.sh

# Or choose a different CNI:
./scripts/k8s-components.sh --cni-calico    # Use Calico instead
./scripts/k8s-components.sh --cni-flannel   # Use Flannel instead
```

> **Note**: After successful bootstrap, the script automatically changes VM boot order from CDROM (ISO) to disk. This ensures VMs boot from the installed Talos on disk instead of the ISO on subsequent reboots.

### Manual Steps

#### Step 1: Generate Machine Configurations

```bash
CLUSTER_NAME="talos-cluster"
MASTER_IP="10.0.0.10"

# Create config directory
mkdir -p talos-cluster

# Generate configurations (done automatically by bootstrap script)
talosctl gen config $CLUSTER_NAME https://$MASTER_IP:6443 \
  --output-dir talos-cluster
```

This generates:

- `talos-cluster/controlplane.yaml` - For master nodes
- `talos-cluster/worker.yaml` - For worker nodes
- `talos-cluster/talosconfig` - Client configuration
- `talos-cluster/certs/` - Extracted certificate files

#### Step 2: Apply Configuration to Master

```bash
# Wait for master to be ready
talosctl wait --nodes 10.0.0.10

# Apply control plane configuration
talosctl apply-config --nodes 10.0.0.10 \
  --file talos-cluster/controlplane.yaml
```

> **Note**: The bootstrap script (`./scripts/talos-bootstrap.sh`) now automatically extracts certificates and creates the correct talosconfig, so manual workaround is no longer needed.

#### Bootstrap Workaround (Talos 1.12+) - Manual Method

If bootstrapping manually (without the script), there may be a certificate mismatch. To fix this:

```bash
# Extract certs from controlplane.yaml (requires yq)
CA_CRT=$(yq -r '.machine.ca.crt' talos-cluster/controlplane.yaml)
ADMIN_CRT=$(yq -r '.machine.kubeadm.admin.crt' talos-cluster/controlplane.yaml)
ADMIN_KEY=$(yq -r '.machine.kubeadm.admin.key' talos-cluster/controlplane.yaml)

# Create talosconfig with correct certs
cat > talos-cluster/talosconfig <<EOF
context: talos-cluster
contexts:
    talos-cluster:
        endpoints:
            - 10.0.0.10
        nodes:
            - 10.0.0.10
        ca: $CA_CRT
        crt: $ADMIN_CRT
        key: $ADMIN_KEY
EOF

# Now bootstrap
talosctl bootstrap --nodes 10.0.0.10 \
  --talosconfig talos-cluster/talosconfig
```

#### Step 3: Apply Configuration to Workers

```bash
# Wait for workers to be ready
talosctl wait --nodes 10.0.0.11
talosctl wait --nodes 10.0.0.12

# Apply worker configuration
talosctl apply-config --nodes 10.0.0.11 \
  --file talos-cluster/worker.yaml

talosctl apply-config --nodes 10.0.0.12 \
  --file talos-cluster/worker.yaml
```

#### Step 4: Bootstrap Kubernetes

```bash
# Bootstrap the first control plane node
talosctl bootstrap --nodes 10.0.0.10
```

#### Step 5: Configure kubectl Access

```bash
# Get kubeconfig
talosctl kubeconfig . --nodes 10.0.0.10

# Or merge with existing kubeconfig
talosctl kubeconfig --merge --nodes 10.0.0.10
```

#### Step 6: Verify Cluster

```bash
# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -A
```

## Scripts Details

### talos-bootstrap.sh

The bootstrap script performs:

1. **Prerequisites Check** - Verifies talosctl, kubectl, VMs running
2. **Generate Configs** - Creates machine configurations
3. **Wait for Nodes** - Ensures all nodes are reachable
4. **Apply Configurations** - Applies configs to master and workers
5. **Bootstrap Cluster** - Initializes Kubernetes control plane
6. **Fetch kubeconfig** - Configures kubectl access
7. **Verify** - Checks cluster health

Usage:

```bash
# Full bootstrap
./scripts/talos-bootstrap.sh

# Bootstrap with custom cluster name
./scripts/talos-bootstrap.sh -n my-cluster

# Skip kubeconfig merge
./scripts/talos-bootstrap.sh --no-merge
```

### k8s-components.sh

Installs general Kubernetes components:

1. **Cilium CNI** (default) - eBPF-based pod networking with Hubble observability
2. **metrics-server** - Resource metrics for HPA
3. **CoreDNS** - Cluster DNS (already in Talos)
4. **kube-proxy** - Service networking (already in Talos)

Usage:

```bash
# Install all components (Cilium + metrics-server)
./scripts/k8s-components.sh

# Install specific CNI
./scripts/k8s-components.sh --cni-cilium    # Cilium (default)
./scripts/k8s-components.sh --cni-calico    # Calico instead
./scripts/k8s-components.sh --cni-flannel   # Flannel instead

# Show available components
./scripts/k8s-components.sh --list
```

## Verification

### Check Talos Nodes

```bash
# List Talos nodes
talosctl get members

# Check node info
talosctl get nodes
```

### Check Kubernetes Cluster

```bash
# Check nodes
kubectl get nodes -o wide

# Check system pods
kubectl get pods -A

# Check cluster info
kubectl cluster-info
```

### Check CNI

```bash
# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Cilium status (requires Cilium CLI)
cilium status

# Check pod networking
kubectl run test --image=nginx --restart=Never
kubectl get pods -o wide
```

### Check Hubble (Cilium Observability)

```bash
# Check Hubble pods
kubectl get pods -n kube-system -l k8s-app=hubble-relay

# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8080:80
# Then open http://localhost:8080
```

### Check metrics-server

```bash
# Check metrics-server pod
kubectl get pods -n kube-system -l k8s-app=metrics-server

# Test metrics API
kubectl top nodes
kubectl top pods -A
```

## Troubleshooting

### Bootstrap fails with "certificate signed by unknown authority"

This is a **known bug in Talos v1.12.0-v1.12.5**. The CA certificate in the generated `talosconfig` doesn't match the node's CA after `apply-config`.

**Solution**: Use Talos v1.11.5:

```bash
# 1. Update .env to use v1.11.5 ISO
echo 'TALOS_IMAGE_URL=https://github.com/siderolabs/talos/releases/download/v1.11.5/metal-amd64.iso' >> .env

# 2. Clean up existing VMs
./scripts/vms-cleanup.sh -f

# 3. Start fresh
./scripts/vms-startup.sh
./scripts/talos-bootstrap.sh
```

**Track the bug**: https://github.com/siderolabs/talos/issues

### Nodes not ready

Check Talos services:

```bash
talosctl services --nodes 10.0.0.10
```

Check logs:

```bash
talosctl logs --nodes 10.0.0.10 --service apid
```

### Bootstrap fails

Reset and retry:

```bash
talosctl reset --nodes 10.0.0.10 --graceful=false
talosctl reset --nodes 10.0.0.11 --graceful=false
talosctl reset --nodes 10.0.0.12 --graceful=false

# Reapply configurations
./scripts/talos-bootstrap.sh
```

### kubectl cannot connect

Regenerate kubeconfig:

```bash
talosctl kubeconfig . --nodes 10.0.0.10 --force
```

### CNI not working

**Check Cilium status:**
```bash
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
```

**Reinstall Cilium:**
```bash
helm uninstall cilium -n kube-system
./scripts/k8s-components.sh --cni-cilium
```

**Check eBPF support:**
```bash
# Cilium requires kernel 5.4+ for full eBPF features
uname -r
```

**Legacy routing mode (if eBPF not supported):**
```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set enable-host-legacy-routing=true
```

### metrics-server fails

Check if metrics API works:

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
```

## Next Steps

After completing this step:

1. ✓ Talos cluster is bootstrapped
2. ✓ Kubernetes is running
3. ✓ Cilium CNI provides eBPF-based pod networking
4. ✓ Hubble provides network observability
5. ✓ metrics-server enables HPA

**Optional:** Install Infisical Secret Manager for secret management:

```bash
# Install Infisical
./scripts/infisical-install.sh

# Access dashboard
kubectl port-forward svc/infisical-ui -n infisical 8081:80
# Open http://localhost:8081
```

**Next:** Install Istio with Envoy Gateway using Helm (see `04-Istio-Envoy-Gateway.md`)

```bash
# Preview: Install Istio
./scripts/istio-install.sh
```

### HPA Study Setup

With Cilium installed, you can now:

1. **Deploy sample application:**
   ```bash
   kubectl apply -f docs/examples/sample-app.yaml
   ```

2. **Configure HPA:**
   ```bash
   kubectl autoscale deployment sample-app --cpu-percent=50 --min=1 --max=10
   ```

3. **Monitor with Hubble:**
   ```bash
   kubectl port-forward -n kube-system svc/hubble-ui 8080:80
   ```

4. **Generate load and observe scaling:**
   ```bash
   kubectl run -i --tty load-generator --image=busybox --restart=Never -- \
     /bin/sh -c "while true; do wget -q -O- http://sample-app; done"
   ```

### Managing Secrets with Infisical

After installing Infisical:

1. **Access the dashboard** at `http://localhost:8081`

2. **Create your first project:**
   - Click "Create Project"
   - Name it (e.g., "sample-app")
   - Add secrets (key-value pairs)

3. **Sync secrets to Kubernetes:**
   ```yaml
   # Create InfisicalSecret CR
   apiVersion: infisical.com/v1alpha1
   kind: InfisicalSecret
   metadata:
     name: sample-app-secrets
     namespace: default
   spec:
     authentication:
       serviceAccountName: sample-app-sa
     infisicalSecret:
       secretPath: /
       environmentName: dev
     managedSecretReference:
       secretName: sample-app-secrets
       secretType: Opaque
   ```

4. **Use secrets in your deployment:**
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: sample-app
   spec:
     template:
       spec:
         containers:
         - name: app
           envFrom:
           - secretRef:
               name: sample-app-secrets
   ```

**Resources:**
- [Infisical Documentation](https://infisical.com/docs/documentation/getting-started/introduction)
- [Kubernetes Operator](https://infisical.com/docs/documentation/getting-started/kubernetes)
- [GitHub Repository](https://github.com/Infisical/infisical)
