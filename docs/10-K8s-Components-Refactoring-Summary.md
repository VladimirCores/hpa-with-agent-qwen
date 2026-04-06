# Kubernetes Components Refactoring - Summary

## Overview

The `k8s-components.sh` script has been refactored from a monolithic script into a modular, step-based architecture following the same pattern as `vms-startup.sh` and `talos-bootstrap.sh`. Additionally, MetalLB LoadBalancer support has been added for external Service exposure.

---

## What Changed

### 1. New Modular Architecture

**Before:** Single monolithic script with all installation logic in one file

**After:** Orchestrator script + individual step scripts

```
scripts/k8s-components.sh          # Orchestrator (rewritten)
scripts/k8s-components/            # Step scripts (new directory)
├── 00-setup.sh                    # Common setup and defaults
├── 01-check-prerequisites.sh      # Verify kubectl, cluster, nodes
├── 02-install-cilium.sh           # Cilium CNI installation
├── 02-install-calico.sh           # Calico CNI installation (alternative)
├── 02-install-flannel.sh          # Flannel CNI installation (alternative)
├── 03-install-metrics-server.sh   # Metrics Server for HPA
├── 04-install-metallb.sh          # MetalLB LoadBalancer (NEW)
└── 05-verify-installation.sh      # Final verification and summary
```

### 2. MetalLB LoadBalancer Support

Added complete MetalLB integration for LoadBalancer-type Services:

- **Layer 2 mode** (default): Simple ARP-based load balancing for NAT/bridged networks
- **BGP mode**: Advanced ECMP load distribution for production setups
- **Dedicated IP pool** for Envoy Gateway integration
- **Configurable IP range** via `.env` file

---

## New Features

### MetalLB Configuration Options

Add to your `.env` file:

```bash
# MetalLB Version
METALLB_VERSION=0.14.8

# Installation method
METALLB_INSTALL_METHOD=helm

# IP Address Pool (50 IPs)
METALLB_IP_POOL_START=192.168.123.200
METALLB_IP_POOL_END=192.168.123.250

# Mode: l2 or bgp
METALLB_MODE=l2

# Envoy Gateway dedicated IP (optional)
ENVOY_GATEWAY_LB_IP=192.168.123.199
```

### Advanced MetalLB Settings

```bash
# L2 Advertisement
METALLB_L2_INTERFACES=eth0           # Limit to specific interfaces
METALLB_L2_NODE_SELECTOR=label=value # Limit to specific nodes

# BGP Settings
METALLB_BGP_MY_ASN=64512
METALLB_BGP_PEER_ASN=64512
METALLB_BGP_PEER_ADDRESS=192.168.123.1
METALLB_BGP_PEER_PORT=179

# Pool Settings
METALLB_AVOID_BUGGY_IPS=true         # Skip .0 and .255
METALLB_AUTO_ASSIGN=true             # Auto-assign IPs to new Services
```

---

## Usage Examples

### Install CNI Only (Default)

```bash
./scripts/k8s-components.sh
```

### Install CNI + MetalLB

```bash
./scripts/k8s-components.sh --with-metallb
```

### Install CNI + Metrics Server + MetalLB

```bash
./scripts/k8s-components.sh --with-metrics --with-metallb
```

### Install MetalLB Only

```bash
./scripts/k8s-components.sh -c metallb
```

### Install Calico Instead of Cilium

```bash
./scripts/k8s-components.sh --cni-calico --with-metallb
```

### Show Help

```bash
./scripts/k8s-components.sh --list
```

---

## MetalLB + Envoy Gateway Integration

### How It Works

1. MetalLB provides LoadBalancer IPs for Kubernetes Services
2. Envoy Gateway creates a LoadBalancer Service automatically
3. MetalLB assigns the configured IP to Envoy Gateway
4. External traffic flows: Client → MetalLB IP → Envoy Gateway → Your services

### Setup Steps

1. **Configure Envoy Gateway IP in `.env`:**
   ```bash
   ENVOY_GATEWAY_LB_IP=192.168.123.199
   ```

2. **Install MetalLB:**
   ```bash
   ./scripts/k8s-components.sh --with-metallb
   ```

3. **Install Istio with Envoy Gateway:**
   ```bash
   ./scripts/istio-install.sh
   ```

4. **Verify:**
   ```bash
   # Check MetalLB IP pools
   kubectl get ipaddresspools.metallb.io -n metallb-system
   
   # Check Envoy Gateway Service
   kubectl get svc -n istio-system
   
   # Should show EXTERNAL-IP: 192.168.123.199
   ```

---

## Testing MetalLB

### Quick Test

```bash
# Create test deployment
kubectl create deployment nginx --image=nginx

# Expose as LoadBalancer
kubectl expose deployment nginx --port=80 --type=LoadBalancer

# Watch for external IP
kubectl get svc -w

# Test connectivity
curl http://<EXTERNAL-IP>
```

### Check MetalLB Status

```bash
# Check pods
kubectl get pods -n metallb-system

# Check IP pools
kubectl get ipaddresspools.metallb.io -n metallb-system

# Check advertisements
kubectl get l2advertisements.metallb.io -n metallb-system
```

---

## Migration Notes

### Backward Compatibility

✅ All existing CLI flags preserved:
- `--cni-cilium`, `--cni-calico`, `--cni-flannel`
- `--with-metrics` or `-m`
- `--list`

✅ Default behavior unchanged:
- Running without flags installs Cilium only
- MetalLB is opt-in (requires `--with-metallb`)

### Breaking Changes

⚠️ None - fully backward compatible

---

## Architecture Benefits

### Modularity

- Each step is independently testable
- Easy to add new components (e.g., Cert-Manager, Prometheus)
- Debug individual steps without running full installation

### Idempotency

- All steps safe to re-run
- Skip already-installed components
- No side effects from multiple executions

### Maintainability

- Clear separation of concerns
- Easy to locate and fix issues
- Follows established project patterns

---

## IP Address Planning

### Your Network Layout

```
192.168.123.1      - Gateway (libvirt network)
192.168.123.10     - talos-master (static DHCP reservation)
192.168.123.20     - talos-worker-1 (static DHCP reservation)
192.168.123.21     - talos-worker-2 (static DHCP reservation)
192.168.123.2-254  - DHCP range (dynamic assignments)

192.168.123.199    - Envoy Gateway (reserved, if configured)
192.168.123.200-250 - MetalLB general pool (50 IPs)
192.168.123.251-254 - Reserved for future use
```

### Pool Allocation

| Pool | Range | Count | Purpose |
|------|-------|-------|---------|
| Envoy Gateway | 192.168.123.199 | 1 IP | Envoy Gateway ingress (optional) |
| General | 192.168.123.200-250 | 50 IPs | Regular LoadBalancer Services |
| **Total** | - | **51 IPs** | - |

---

## Documentation

### New Documentation

- **`docs/09-MetalLB-LoadBalancer.md`**: Complete MetalLB guide
  - Installation steps
  - Configuration examples
  - Envoy Gateway integration
  - Usage examples
  - Troubleshooting guide

### Updated Documentation

- **`QWEN.md`**: Added MetalLB references
  - Key Technologies table
  - Next Steps section
  - Resources section

---

## Files Changed

### New Files (9)

```
scripts/k8s-components/00-setup.sh
scripts/k8s-components/01-check-prerequisites.sh
scripts/k8s-components/02-install-cilium.sh
scripts/k8s-components/02-install-calico.sh
scripts/k8s-components/02-install-flannel.sh
scripts/k8s-components/03-install-metrics-server.sh
scripts/k8s-components/04-install-metallb.sh
scripts/k8s-components/05-verify-installation.sh
docs/09-MetalLB-LoadBalancer.md
```

### Modified Files (3)

```
scripts/k8s-components.sh         # Complete rewrite as orchestrator
.env.example                      # Added MetalLB configuration section
QWEN.md                           # Added MetalLB references
```

---

## Next Steps

1. **Test the installation:**
   ```bash
   # Start cluster
   ./scripts/vms-startup.sh
   ./scripts/talos-bootstrap.sh
   
   # Install components
   ./scripts/k8s-components.sh --with-metrics --with-metallb
   ```

2. **Verify MetalLB:**
   ```bash
   kubectl get pods -n metallb-system
   kubectl get ipaddresspools.metallb.io -n metallb-system
   ```

3. **Install Envoy Gateway:**
   ```bash
   ./scripts/istio-install.sh
   ```

4. **Test LoadBalancer Services:**
   ```bash
   # See docs/09-MetalLB-LoadBalancer.md for examples
   ```

---

## Troubleshooting

### Common Issues

**MetalLB pods not starting:**
```bash
kubectl describe pod -n metallb-system -l component=controller
kubectl logs -n metallb-system -l component=controller
```

**Service stuck in Pending:**
```bash
# Check IP pool exhaustion
kubectl get ipaddresspools.metallb.io -n metallb-system

# Expand pool in .env
METALLB_IP_POOL_END=192.168.123.254
```

**Service unreachable:**
```bash
# Check L2 advertisement
kubectl get l2advertisements.metallb.io -n metallb-system

# Verify ARP from host
arping -I <interface> <service-ip>
```

---

## Summary

✅ **Refactored** `k8s-components.sh` into modular step-based architecture  
✅ **Added** MetalLB LoadBalancer support with Layer 2 and BGP modes  
✅ **Prepared** for Envoy Gateway integration with dedicated IP pool  
✅ **Updated** `.env.example` with comprehensive MetalLB configuration  
✅ **Created** complete documentation with examples and troubleshooting  
✅ **Maintained** full backward compatibility  

All changes follow established project patterns and conventions.
