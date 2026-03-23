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

The startup script executes the following modular steps **asynchronously**:

| Step | Script                      | Description                                             |
| ---- | --------------------------- | ------------------------------------------------------- |
| 00   | `00-helper-functions.sh`    | Common functions (get_libvirt_ips, check_machine_ready) |
| 01   | `01-authenticate-sudo.sh`   | Sudo authentication (cached for 15 min)                 |
| 02   | `02-check-prerequisites.sh` | Verify Vagrantfile, vagrant-libvirt, libvirtd           |
| 03   | `03-prepare-iso.sh`         | Download/verify Talos ISO                               |
| 04   | `04-copy-iso-to-pool.sh`    | Copy ISO to storage pool                                |
| 05   | `05-setup-network.sh`       | Run `prepare-network.sh`                                |
| 06   | `06-cleanup-vms.sh`         | Remove old VM disks (unless `-s` flag)                  |
| 07   | `07-start-vms.sh`           | Start VMs via Vagrant                                   |
| 08   | `08-wait-for-talos.sh`      | Wait for Talos READY (runs async)                       |
| 09   | `09-eject-iso.sh`           | Eject ISO from all VMs, set disk boot                   |
| 10   | `10-reboot-verify.sh`       | Reboot VMs, verify disk boot (polls IPs)                |
| 11   | `11-summary.sh`             | Display summary and next steps                          |

**Execution flow**:

```
All steps (01-11) start simultaneously in background
     ↓
Main script waits for all steps to complete
     ↓
Reports success/failure for each step
```

**Total time**: ~5-10 minutes (includes Talos boot time + reboot verification)

**Benefits of async execution**:

- Faster overall execution (parallel processing)
- Non-blocking operations
- Independent step failure doesn't stop other steps
- Better resource utilization

**Script structure**:

```
scripts/vms-startup.sh          # Main script (50 lines)
scripts/vms-startup/
├── 00-helper-functions.sh      # Common functions
├── 01-authenticate-sudo.sh     # Step 1: Sudo auth
├── 02-check-prerequisites.sh   # Step 2: Prerequisites
├── 03-prepare-iso.sh           # Step 3: ISO preparation
├── 04-copy-iso-to-pool.sh      # Step 4: Copy ISO
├── 05-setup-network.sh         # Step 5: Network setup
├── 06-cleanup-vms.sh           # Step 6: Cleanup disks
├── 07-start-vms.sh             # Step 7: Start VMs
├── 08-wait-for-talos.sh        # Step 8: Wait for READY
├── 09-eject-iso.sh             # Step 9: Eject ISO
├── 10-reboot-verify.sh         # Step 10: Reboot & verify
└── 11-summary.sh               # Step 11: Summary
```

**Key improvements**:

- Steps 08-10 use `libvirt_get_dhcp_ips()` with named parameters
- Intuitive function signature: `libvirt_get_dhcp_ips -n <network> -p <protocol>`
- No complex VM name ↔ IP matching logic
- Faster execution (fewer virsh calls)
- Simpler, more maintainable code

**Helper function usage**:

```bash
# Get all IPv4 addresses from network
mapfile -t IPS < <(libvirt_get_dhcp_ips -n cluster-talos-net -p ipv4)

# Get all IPs (IPv4 + IPv6)
mapfile -t IPS < <(libvirt_get_dhcp_ips -n my-network -p all)

# Show help
libvirt_get_dhcp_ips --help
```

**Running steps independently**:

Steps can be run independently for testing or debugging:

```bash
# Run a specific step (helper functions auto-loaded)
NETWORK_NAME=cluster-talos-net bash scripts/vms-startup/08-wait-for-talos.sh

# Run step 10 (reboot verification)
NETWORK_NAME=cluster-talos-net bash scripts/vms-startup/10-reboot-verify.sh
```

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
