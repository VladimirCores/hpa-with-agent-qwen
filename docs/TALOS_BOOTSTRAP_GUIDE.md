# Talos Cluster Setup - Correct Order and Common Issues

## Root Cause of Your Error

The error you encountered:
```
error executing reboot: rpc error: code = Unavailable desc = connection error: desc = "transport: authentication handshake failed: tls: failed to verify certificate: x509: certificate signed by unknown authority"
```

This happened because the **bootstrap script was applying configuration and rebooting the node BEFORE running bootstrap**, which caused the node to generate new certificates. When the bootstrap command finally ran, it couldn't authenticate because:

1. The node was rebooted with new PKI (certificates)
2. The `talosconfig` had old/different certificates
3. Bootstrap requires either:
   - **Maintenance mode** (no certs, use `--insecure` flag), OR
   - Matching certificates between client and server

**Additional Issue:** The `--insecure` flag was being used incorrectly. In Talos v1.13+, the bootstrap command needs both:
- The `--insecure` flag to accept self-signed maintenance mode certificates
- The correct `TALOSCONFIG` path set via environment variable or `--talosconfig` flag

## Correct Talos Bootstrap Order

### Phase 1: Preparation (Before VM Boot)
1. **Generate secrets** - Creates cluster secrets file
2. **Generate configs** - Creates `controlplane.yaml`, `worker.yaml`, and `talosconfig`

### Phase 2: Bootstrap (CRITICAL ORDER)
3. **Ensure node is in maintenance mode** - VM boots from ISO/disk without config
4. **Run bootstrap FIRST** - `talosctl bootstrap --insecure` (node has no certs yet)
5. **Wait for cluster to initialize** - etcd starts, API server comes up
6. **Apply machine configs** - `talosctl apply-config` with proper talosconfig
7. **Join worker nodes** - Workers apply their configs and join cluster

### Phase 3: Post-Bootstrap
8. Configure kubectl
9. Install CNI (Cilium/Calico)
10. Install additional components

## Key Principles

### 1. Bootstrap Before Any Config Apply
```bash
# WRONG ORDER (causes your error):
talosctl apply-config --insecure --file controlplane.yaml  # Applies config
talosctl reboot                                            # Reboots, generates certs
talosctl bootstrap --talosconfig talosconfig              # FAILS - cert mismatch!

# CORRECT ORDER:
talosctl bootstrap --insecure                              # Bootstrap first (no certs)
talosctl apply-config --talosconfig talosconfig            # Then apply config
```

### 2. Maintenance Mode Detection
A node is in maintenance mode when:
- `talosctl version --insecure` returns version info
- `talosctl version --talosconfig` fails with "certificate signed by unknown authority"

### 3. Use Correct Authentication Flags
- **Maintenance mode**: Use `--insecure` flag (no certificates)
- **After bootstrap**: Use `--talosconfig <path>` (with certificates)

## Fixed Script Changes

The updated `05-bootstrap-cluster.sh` now:

1. **Checks node state properly** - Detects if node is in maintenance mode vs. has certs
2. **Uses --insecure for bootstrap** - Bootstrap always uses insecure mode
3. **Sets TALOSCONFIG environment variable** - Ensures talosctl uses the correct config file
4. **No premature reboots** - Removed reboot before bootstrap
5. **Better error handling** - Clear troubleshooting steps

## Manual Recovery Steps

If you're stuck with the current error:

### Option 1: Reset Node to Maintenance Mode
```bash
# Reset the control plane node
talosctl reset --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure --graceful=false --wait=false

# Wait for reset (30-60 seconds)
sleep 30

# Verify maintenance mode
talosctl version --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure

# Run bootstrap
talosctl bootstrap --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure

# Apply config AFTER bootstrap
talosctl apply-config --nodes 192.168.123.10 --endpoints 192.168.123.10 \
  --file talos-cluster/controlplane.yaml \
  --talosconfig talos-cluster/talosconfig
```

### Option 2: Full Cluster Reset
```bash
# Stop all VMs
virsh destroy talos-master
virsh destroy talos-worker-1
virsh destroy talos-worker-2
virsh destroy talos-worker-3

# Clean old configs (keep secrets!)
rm -f talos-cluster/*.yaml talos-cluster/talosconfig

# Regenerate configs
./scripts/talos-bootstrap/03-generate-configs.sh

# Start VMs
virsh start talos-master
virsh start talos-worker-1
virsh start talos-worker-2
virsh start talos-worker-3

# Wait for VMs to boot
sleep 60

# Bootstrap fresh
./scripts/talos-bootstrap/05-bootstrap-cluster.sh
```

## VM Boot Configuration

Ensure your VMs are configured correctly:

### Boot Order (Critical!)
1. **Hard Disk** (first) - For normal operation
2. **CDROM** (second) - For initial install from ISO

### For Initial Install
- VM boots from ISO
- Talos runs in maintenance mode
- Bootstrap applies config to disk
- Reboot from hard disk

### After Install
- VM boots from hard disk
- Talos loads applied configuration
- Node joins cluster

## Verification Commands

```bash
# Check node state (maintenance mode)
talosctl version --nodes 192.168.123.10 --endpoints 192.168.123.10 --insecure

# Check node state (after bootstrap)
talosctl version --nodes 192.168.123.10 --endpoints 192.168.123.10 --talosconfig talos-cluster/talosconfig

# Check cluster members
talosctl get members --nodes 192.168.123.10 --endpoints 192.168.123.10 --talosconfig talos-cluster/talosconfig

# Check etcd members
talosctl get etcdmembers --nodes 192.168.123.10 --endpoints 192.168.123.10 --talosconfig talos-cluster/talosconfig

# Check machine config
talosctl get machineconfig --nodes 192.168.123.10 --endpoints 192.168.123.10 --talosconfig talos-cluster/talosconfig
```

## Recommended Workflow

```bash
# Complete fresh installation
cd /workspace

# 1. Generate secrets (if not exists)
./scripts/talos-bootstrap/02-generate-secrets.sh

# 2. Generate configs
./scripts/talos-bootstrap/03-generate-configs.sh

# 3. Ensure VMs are running and booted
./scripts/vms-startup.sh

# 4. Wait for VMs to be ready (pingable)
./scripts/talos-bootstrap/01-check-prerequisites.sh

# 5. Bootstrap cluster (BEFORE applying configs!)
./scripts/talos-bootstrap/05-bootstrap-cluster.sh

# 6. Apply machine configs (AFTER bootstrap)
./scripts/talos-bootstrap/06-apply-configs.sh

# 7. Verify bootstrap
./scripts/talos-bootstrap/07-verify-bootstrap.sh

# 8. Configure kubectl
./scripts/talos-bootstrap/08-configure-kubectl.sh

# 9. Install CNI and other components
./scripts/k8s-components.sh
```

## Additional Resources

- [Talos Documentation](https://www.talos.dev/latest/)
- [Talos Bootstrap Guide](https://www.talos.dev/latest/talos-guides/install/bare-metal-platforms/standard/)
- [Talos Certificate Management](https://www.talos.dev/latest/learn-more/architecture/#security)
