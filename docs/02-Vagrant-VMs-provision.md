# Vagrant VMs Provisioning for Talos Cluster

This document describes how to provision Talos cluster VMs using Vagrant with libvirt.

## Overview

The Vagrant configuration creates a Talos cluster with one master node and configurable worker nodes on an isolated libvirt network with static DHCP reservations.

### Cluster Architecture

| Component  | Description                           |
| ---------- | ------------------------------------- |
| Provider   | libvirt (QEMU/KVM)                    |
| Network    | Isolated NAT network with static DHCP |
| Storage    | Directory-based storage pool          |
| Boot Media | Talos ISO (downloaded automatically)  |

### Default VM Configuration

| Node           | CPUs | Memory | Disk | IP Address | MAC Address        |
| -------------- | ---- | ------ | ---- | ---------- | ------------------ |
| talos-master   | 4    | 4096MB | -    | 10.0.0.10  | `${MAC_PREFIX}:01` |
| talos-worker-1 | 1    | 2048MB | -    | 10.0.0.11  | `${MAC_PREFIX}:0b` |
| talos-worker-2 | 1    | 2048MB | -    | 10.0.0.12  | `${MAC_PREFIX}:0c` |

> **Note:** MAC addresses use the `MAC_PREFIX` from `.env` (default: `52:54:00:00:00`).

## Prerequisites

- Vagrant installed
- libvirt installed and running
- `vagrant-libvirt` plugin installed:
  ```bash
  vagrant plugin install vagrant-libvirt
  ```
- `.env` file configured (copy from `.env.example`)

## Configuration

Edit `.env` to customize your cluster:

```bash
# Network Configuration
NETWORK_NAME=cluster-talos-net
BRIDGE_NAME=talos-bridge
NETWORK_CIDR=10.0.0.1/24
NETWORK_IP=10.0.0.1
NETWORK_MASK=255.255.255.0
DHCP_START=10.0.0.2
DHCP_END=10.0.0.254
FORWARD_MODE=nat

# Storage Configuration
STORAGE_POOL=talos-pool

# Master Node Configuration
MASTER_NAME=talos-master
MASTER_IP=10.0.0.10
MASTER_CPUS=4
MASTER_MEMORY=4096

# Worker Nodes Configuration
WORKER_COUNT=2
WORKER_NAME_PREFIX=talos-worker-
WORKER_IP_BASE=10.0.0.11
WORKER_CPUS=1
WORKER_MEMORY=2048

# MAC Address Prefix
MAC_PREFIX=52:54:00:00:00

# Cluster Name (for talosctl)
CLUSTER_NAME=talos-default
```

## Usage

### Start Cluster

Start the cluster (cleans up existing VMs first):

```bash
./scripts/vms-startup.sh
```

Start without cleanup (preserves existing VMs):

```bash
./scripts/vms-startup.sh -s
```

### Stop Cluster

Full cleanup (default - removes everything):

```bash
./scripts/vms-cleanup.sh
```

Preserve network during cleanup:

```bash
./scripts/vms-cleanup.sh -n
```

> **Note**: Full cleanup removes VMs, volumes, network, and storage pool. Everything is recreated on next `vms-startup.sh`.

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

# SSH into a VM (if supported)
vagrant ssh talos-master
```

## Scripts Details

### vms-startup.sh

The startup script performs the following steps:

1. **Sudo Authentication** - Authenticates and caches credentials for 15 minutes
2. **Prerequisites Check** - Verifies Vagrantfile, vagrant-libvirt plugin, libvirtd
3. **ISO Preparation** - Downloads Talos ISO if not present or corrupted
4. **Storage Pool Setup** - Creates pool if needed, copies ISO
5. **Network Setup** - Runs `prepare-network.sh` to create isolated network
6. **Cleanup** - Removes existing VMs (unless `-s` flag used)
7. **VM Startup** - Starts all VMs via Vagrant
8. **Verification** - Checks VM status and DHCP leases
9. **Summary** - Displays next steps

### vms-cleanup.sh

The cleanup script performs full cleanup by default:

| Action              | Default |
| ------------------- | ------- |
| Stop VMs            | ✓ Yes   |
| Remove volumes      | ✓ Yes   |
| Destroy network     | ✓ Yes   |
| Remove storage pool | ✓ Yes   |

Options:

- `-n` - Preserve network (still removes VMs, volumes, and pool)

> **Note**: Everything is recreated on next `vms-startup.sh` run.

## Verification

### Check VM Status

```bash
# List all VMs
virsh -c qemu:///system list --all

# Check specific VM
virsh -c qemu:///system dominfo talos-master
```

### Check Network

```bash
# List networks
virsh -c qemu:///system net-list --all

# Show network details
virsh -c qemu:///system net-info cluster-talos-net

# Show DHCP leases
virsh -c qemu:///system net-dhcp-leases cluster-talos-net
```

### Check Storage

```bash
# List volumes in pool
virsh -c qemu:///system vol-list --pool talos-pool

# Check pool info
virsh -c qemu:///system pool-info talos-pool
```

## Troubleshooting

### VMs fail to start

Check libvirtd is running:

```bash
systemctl status libvirtd
```

Check vagrant-libvirt plugin:

```bash
vagrant plugin list | grep libvirt
```

### Network not created

Run network setup manually:

```bash
./scripts/prepare-network.sh
```

Check for existing network conflicts:

```bash
virsh -c qemu:///system net-list --all
```

### ISO download fails

Download manually:

```bash
curl -L -o metal-amd64.iso https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso
```

### Permission denied errors

Ensure your user is in the libvirt group:

```bash
sudo usermod -aG libvirt $USER
# Log out and back in
```

### DHCP not assigning expected IPs

Verify MAC addresses match static reservations:

```bash
virsh -c qemu:///system net-dumpxml cluster-talos-net | grep -A 20 '<dhcp>'
```

Check VM MAC addresses:

```bash
virsh -c qemu:///system domdumpxml talos-master | grep -A 5 '<interface>'
```

### Sudo cache issues

Clear sudo cache manually:

```bash
rm -f /tmp/sudo_cache_$(whoami)
```

## Next Steps

After VMs are running:

1. Wait for Talos to boot (~30 seconds)
2. Generate machine configurations:
   ```bash
   talosctl gen config talos-default https://10.0.0.10:6443
   ```
3. Apply configurations with talosctl (see `03-Talos-Configuration.md`)
