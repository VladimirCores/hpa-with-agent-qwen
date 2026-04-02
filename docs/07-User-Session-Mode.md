# User Session Mode for Talos Cluster

This document explains the **user session mode** configuration for running the Talos Kubernetes cluster.

## Overview

This cluster runs **exclusively in user session mode** (`qemu:///session`). This means:

- ✅ **No sudo required** - All operations run as your user
- ✅ **Project-local storage** - VM disks stored in `.vagrant/storage-pool/`
- ✅ **User-isolated** - VMs only visible to your user session
- ✅ **Portable** - Entire cluster in project folder

## When NOT to Use This Setup

This setup is **NOT suitable** if you need:
- ❌ Bridged networking (VMs on physical network)
- ❌ VMs accessible from other hosts
- ❌ System-wide VM management
- ❌ VMs that persist across user sessions

For those requirements, you need a different libvirt configuration.

## Quick Start (Session Mode)

### Step 1: Configure Environment

```bash
# Copy environment file
cp .env.example .env

# Edit .env to use session mode
sed -i 's|LIBVIRT_URI=qemu:///system|# LIBVIRT_URI=qemu:///system|' .env
sed -i 's|# LIBVIRT_URI=qemu:///session|LIBVIRT_URI=qemu:///session|' .env

# Verify the change
grep LIBVIRT_URI .env
# Should show: LIBVIRT_URI=qemu:///session
```

### Step 2: Start the Cluster

```bash
# No sudo required!
./scripts/vms-startup.sh

# Bootstrap Talos
./scripts/talos-bootstrap.sh

# Install Cilium
./scripts/k8s-components.sh
```

## Configuration Changes

### .env Settings

```bash
# Libvirt URI (change from system to session)
LIBVIRT_URI=qemu:///session

# Storage pool (auto-calculated if not set)
# For session mode, defaults to:
# POOL_PATH=$HOME/.local/share/libvirt/talos-pool
STORAGE_POOL=talos-pool

# Network settings (same as system mode)
NETWORK_NAME=cluster-talos-net
NETWORK_CIDR=10.0.0.1/24
```

### Storage Locations

| Resource | System Mode | Session Mode | Project-Local (Default) |
|----------|-------------|--------------|------------------------|
| **VM Disks** | `/var/lib/libvirt/talos-pool/` | `~/.local/share/libvirt/talos-pool/` | `./.vagrant/storage-pool/` |
| **Networks** | System libvirt | User libvirt | User/System libvirt |
| **Configs** | System-wide | User-only | Project directory |

**Project-local storage is recommended** because:
- ✅ Portable (entire cluster in project folder)
- ✅ No sudo required for storage operations
- ✅ Easy cleanup (just delete `.vagrant/storage-pool/`)
- ✅ Works with both system and session mode
- ✅ No permission issues

## Networking in Session Mode

### What Works

- ✅ NAT networking (VMs can reach outside)
- ✅ Port forwarding (host → VM)
- ✅ DHCP reservations (static IPs)
- ✅ Inter-VM communication
- ✅ Host → VM communication

### What Doesn't Work

- ❌ Bridged networking (VMs on physical network)
- ❌ macvtap (direct NIC access)
- ❌ VM accessible from other hosts (without port forwarding)
- ❌ Direct hardware access

### Network Configuration

Session mode uses NAT by default:

```
┌─────────────────────────────────────────┐
│         Host Network (192.168.x.x)      │
│              ┌──────────┐               │
│              │  NAT     │               │
│              │ Gateway  │               │
│              └────┬─────┘               │
│                   │ 10.0.0.1            │
│         ┌─────────┴─────────┐           │
│    10.0.0.10   10.0.0.11   10.0.0.12   │
│   ┌──────┐  ┌──────  ┌──────┐        │
│   │Master│  │Worker│  │Worker│        │
│   │      │  │  -1   │  │  -2   │        │
│   └──────┘  └──────  └──────┘        │
└─────────────────────────────────────────┘
```

### Accessing Services

```bash
# From host (works same as system mode)
kubectl --kubeconfig talos-cluster/kubeconfig get nodes

# From outside host (requires port forwarding)
# Set up port forwarding in Vagrantfile or use ssh tunnel
```

## Session Mode Commands

### Start Cluster

```bash
# No sudo needed
./scripts/vms-startup.sh
```

### Stop Cluster

```bash
# No sudo needed
./scripts/vms-cleanup.sh
```

### Full Cleanup

```bash
# Destroys network and storage pool
./scripts/vms-cleanup.sh -n
```

### Check VM Status

```bash
# Session mode VMs
virsh -c qemu:///session list --all

# System mode VMs (if you have both)
virsh -c qemu:///system list --all
```

### Check Networks

```bash
# Session networks
virsh -c qemu:///session net-list --all

# System networks
virsh -c qemu:///system net-list --all
```

### Check Storage

```bash
# Session storage pools
virsh -c qemu:///session pool-list --all

# System storage pools
virsh -c qemu:///system pool-list --all
```

## Troubleshooting

### Session Mode Not Starting

```bash
# Check libvirt session socket
ls -la ~/.local/share/libvirt/

# Check user permissions
id
groups

# Verify session libvirt is running
virsh -c qemu:///session list --all
```

### Network Not Working

```bash
# Check network definition
virsh -c qemu:///session net-dump-xml cluster-talos-net

# Check DHCP leases
virsh -c qemu:///session net-dhcp-leases cluster-talos-net

# Restart network
virsh -c qemu:///session net-destroy cluster-talos-net
virsh -c qemu:///session net-start cluster-talos-net
```

### Storage Pool Issues

```bash
# Check pool exists
virsh -c qemu:///session pool-info talos-pool

# List volumes
virsh -c qemu:///session vol-list --pool talos-pool

# Recreate pool
./scripts/vms-startup.sh  # Auto-creates if missing
```

### Permission Denied

Session mode should not require sudo. If you see permission errors:

```bash
# Check user owns the directory
ls -la ~/.local/share/libvirt/

# Fix ownership
chown -R $USER:$USER ~/.local/share/libvirt/

# Check libvirt session socket
ls -la $XDG_RUNTIME_DIR/libvirt/
```

## Switching Between Modes

### System → Session

```bash
# 1. Clean up system mode
export LIBVIRT_URI=qemu:///system
./scripts/vms-cleanup.sh -n

# 2. Switch to session mode
export LIBVIRT_URI=qemu:///session
# Or edit .env: LIBVIRT_URI=qemu:///session

# 3. Start in session mode
./scripts/vms-startup.sh
```

### Session → System

```bash
# 1. Clean up session mode
export LIBVIRT_URI=qemu:///session
./scripts/vms-cleanup.sh -n

# 2. Switch to system mode
export LIBVIRT_URI=qemu:///system
# Or edit .env: LIBVIRT_URI=qemu:///system

# 3. Start in system mode (requires sudo)
./scripts/vms-startup.sh
```

## Performance Comparison

| Metric | System Mode | Session Mode |
|--------|-------------|--------------|
| **CPU** | Same (KVM) | Same (KVM) |
| **Memory** | Same | Same |
| **Disk I/O** | Same | Same |
| **Network** | Full features | NAT only |
| **Startup** | ~5-7 min | ~5-7 min |

## Security Considerations

### Session Mode Benefits

- VMs isolated to user session
- No root access required
- VMs stop when user logs out
- Storage in user home directory

### System Mode Benefits

- VMs persist across user sessions
- Can be managed by system services
- Better for production-like setups

## Best Practices

1. **Use session mode for development** - No sudo, isolated, safe
2. **Use system mode for testing production** - Full networking, persistent
3. **Clean up properly** - Use `./scripts/vms-cleanup.sh -n` for full cleanup
4. **Check mode before commands** - `echo $LIBVIRT_URI`
5. **Document your choice** - Note in team docs which mode you use

## Resources

- [Libvirt URI Formats](https://libvirt.org/uri.html)
- [Libvirt Session vs System](https://wiki.libvirt.org/page/FAQ#What_is_the_difference_between_system_and_session_QEMU_instances.3F)
- [QEMU User Session](https://wiki.qemu.org/Documentation/UsbAssignment)

## Known Limitations

### Network Creation in Session Mode

**Issue:** Libvirt session mode requires permission to create network bridge interfaces, which is typically not granted to regular users.

**Error:** `error creating bridge interface virbr1: Operation not permitted`

**Workaround:** Use system mode (`qemu:///system`) for full networking support, or configure polkit rules to allow network creation:

```bash
# Create polkit rule (requires admin access)
sudo cat > /etc/polkit-1/rules.d/50-libvirt-networks.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.network.create" &&
        subject.isInGroup("libvirt")) {
        return polkit.Result.YES;
    }
});
POLKIT
```

**Recommendation:** For most users, system mode (`qemu:///system`) is recommended as it provides full networking without additional configuration.
