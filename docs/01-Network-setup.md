# Network Setup for Talos Cluster

This document describes how to set up the isolated libvirt network for the Talos cluster.

## Overview

The network configuration creates an isolated NAT network with static DHCP reservations for all cluster nodes.

### Network Details

| Setting      | Value                |
| ------------ | -------------------- |
| Network Name | `cluster-net`        |
| Bridge Name  | `cluster-bridge`     |
| Network CIDR | `192.168.123.1/24`   |
| Gateway IP   | `192.168.123.1`      |
| Forward Mode | NAT (or bridge mode) |

### Static IP Reservations

| Node           | IP Address      | MAC Address        |
| -------------- | --------------- | ------------------ |
| talos-master   | 192.168.123.10  | `${MAC_PREFIX}:01` |
| talos-worker-1 | 192.168.123.20  | `${MAC_PREFIX}:0b` |
| talos-worker-2 | 192.168.123.21  | `${MAC_PREFIX}:0c` |

> **Note:** MAC addresses are generated using the `MAC_PREFIX` from `.env` (default: `52:54:00:00:00`).

## Prerequisites

- libvirt installed and running
- `virsh` CLI tool available
- User has permissions to manage libvirt networks (typically requires being in the `libvirt` group or running as root)

## Usage

### Run the Network Setup Script

```bash
./scripts/prepare-network.sh
```

The script will:

1. Load configuration from `.env`
2. Check if `cluster-talos-net` already exists
3. Delete the existing network if found (destroy + undefine)
4. Create a new network with static DHCP reservations
5. Start the network
6. Enable autostart on boot

### Verify Network Setup

```bash
# List all networks
virsh net-list --all

# Show network details
virsh net-info cluster-net

# Show DHCP leases (after VMs are running)
virsh net-dhcp-leases cluster-net
```

### Manual Network Management

```bash
# Destroy (stop) the network
virsh net-destroy cluster-net

# Undefine (delete) the network
virsh net-undefine cluster-net

# Define network from XML
virsh net-define /path/to/network.xml

# Start the network
virsh net-start cluster-talos-net

# Enable autostart
virsh net-autostart cluster-talos-net
```

## Configuration

Edit `.env` to customize network settings:

```bash
# Network Configuration
NETWORK_NAME=cluster-net
BRIDGE_NAME=cluster-bridge
NETWORK_CIDR=192.168.123.1/24
NETWORK_IP=192.168.123.1
NETWORK_MASK=255.255.255.0
DHCP_START=192.168.123.2
DHCP_END=192.168.123.254
FORWARD_MODE=nat

# MAC Address Prefix (used for static reservations)
MAC_PREFIX=52:54:00:00:00

# Node Configuration (for static IP reservations)
MASTER_NAME=talos-master
MASTER_IP=192.168.123.10
WORKER_COUNT=2
WORKER_NAME_PREFIX=talos-worker-
WORKER_IP_BASE=192.168.123.20
```

The `MAC_PREFIX` should be the first 5 octets of a MAC address (colon-separated). The script appends the last octet automatically:

- Master gets `:01`
- Workers get `:0b`, `:0c`, etc. (hex values 11, 12...)

## VM Network Configuration

When creating VMs, ensure they use the correct MAC addresses to receive their static IPs:

```xml
<interface type='network'>
  <source network='cluster-talos-net'/>
  <mac address='52:54:00:00:00:01'/>
  <model type='virtio'/>
</interface>
```

Or with Vagrant libvirt provider:

```ruby
config.vm.network :private_network,
  type: 'dhcp',
  mac: '525400000001',
  libvirt__network_name: 'cluster-talos-net'
```

### MAC Address Assignment

The script generates MAC addresses using the `MAC_PREFIX` from `.env`:

- **Master**: `${MAC_PREFIX}:01` (e.g., `52:54:00:00:00:01`)
- **Worker 1**: `${MAC_PREFIX}:0b` (e.g., `52:54:00:00:00:0b`)
- **Worker 2**: `${MAC_PREFIX}:0c` (e.g., `52:54:00:00:00:0c`)

Workers use hex values 11, 12, etc. (0x0b, 0x0c) to avoid conflicts with the master.

## Troubleshooting

### Network already exists

Run the script again - it will automatically delete and recreate the network.

### Permission denied

Ensure your user is in the libvirt group:

```bash
sudo usermod -aG libvirt $USER
# Log out and back in for changes to take effect
```

### DHCP not assigning reserved IPs

Verify the VM's MAC address matches the reservation in the network definition:

```bash
virsh net-dumpxml cluster-net | grep -A 20 '<dhcp>'
```

### MAC address conflicts

Ensure each VM has a unique MAC address. The script assigns:

- Master: `${MAC_PREFIX}:01`
- Worker N: `${MAC_PREFIX}:${N+10}` (in hex)

If you change `MAC_PREFIX` in `.env`, recreate the network:

```bash
./scripts/prepare-network.sh
```
