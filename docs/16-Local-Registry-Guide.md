# Local Registry Guide

This guide explains how to set up and use a local Podman registry to cache Kubernetes and Talos images, ensuring all cluster components pull images from the local cache instead of remote registries.

## Overview

The local registry provides:
- **Faster deployments**: No need to pull images from remote registries
- **Offline capability**: Works without internet access after initial population
- **Consistent versions**: Ensures all nodes use the same image versions
- **Reduced bandwidth**: Images are pulled once and cached locally

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Remote         │────▶│  Local Podman    │────▶│  Talos Cluster  │
│  Registries     │     │  Registry        │     │  Nodes          │
│  (docker.io,    │     │  (host:5000)     │     │                 │
│   quay.io, etc) │     │                  │     │                 │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                              ▲
                              │
                    All images cached here
```

## Quick Start

### 1. Start the Local Registry

```bash
./scripts/start-local-registry.sh
```

This creates a Podman container running the Docker registry v2 image on port 5000.

### 2. Populate the Registry Cache

```bash
./scripts/populate-local-registry.sh
```

This script:
- Pulls all required images from remote registries
- Tags them for the local registry URL
- Pushes them to the local cache
- Provides a summary of cached images

**Note**: This may take several minutes depending on your internet connection.

### 3. Verify Registry Configuration

```bash
./scripts/verify-local-registry.sh
```

This checks:
- Registry container status
- Registry accessibility
- Cached images presence
- Talos configuration mirror settings

### 4. Generate Talos Configuration with Mirrors

```bash
./scripts/talos-bootstrap/03-generate-configs.sh
```

This automatically configures registry mirrors in the Talos machine configs for:
- `docker.io`
- `registry.k8s.io`
- `quay.io`
- `ghcr.io`
- `gcr.io`

### 5. Bootstrap the Cluster

```bash
./scripts/talos-bootstrap.sh
```

The cluster will now pull all images from the local registry.

## Cached Images

The following images are cached:

### Core Infrastructure
- Talos installer and kubelet
- Kubernetes control plane (apiserver, controller-manager, scheduler, proxy)
- etcd, pause, coredns

### CNI Providers
- **Cilium** (default): cilium, operator-generic, hubble-*
- **Calico** (alternative): node, kube-controllers, cni, typha
- **Flannel** (simple): flannel, flannel-cni-plugin

### Add-ons
- Metrics Server
- MetalLB (controller, speaker)
- Kubernetes Dashboard
- Cert Manager

### Optional Components
- Istio (pilot, proxyv2)
- Envoy Gateway
- Infisical Secret Manager
- PostgreSQL (for Infisical)

## Configuration Details

### Registry Mirror Configuration

Talos machines are configured with mirrors in `talos-cluster/controlplane.yaml`:

```yaml
machine:
  registries:
    mirrors:
      docker.io:
        endpoints:
          - "http://192.168.123.1:5000"
      registry.k8s.io:
        endpoints:
          - "http://192.168.123.1:5000"
      quay.io:
        endpoints:
          - "http://192.168.123.1:5000"
      ghcr.io:
        endpoints:
          - "http://192.168.123.1:5000"
      gcr.io:
        endpoints:
          - "http://192.168.123.1:5000"
    config:
      "192.168.123.1:5000":
        tls:
          insecureSkipVerify: true
```

### Network Configuration

The registry URL is derived from your `.env` file:
- `NETWORK_IP`: Host network IP (default: 192.168.123.1)
- Registry URL: `${NETWORK_IP}:5000`

Ensure VMs can reach this IP address.

## Maintenance

### Check Registry Status

```bash
podman ps | grep local-registry
curl http://localhost:5000/v2/_catalog
```

### List Cached Images

```bash
podman images | grep "192.168.123.1:5000"
```

### Add New Images

Edit `scripts/populate-local-registry.sh` and add to the `IMAGES` array:

```bash
IMAGES=(
    # ... existing images ...
    "docker.io/myorg/myimage:v1.0.0"
)
```

Then re-run the populate script.

### Clean Up

```bash
# Stop registry
podman stop local-registry

# Remove registry container
podman rm local-registry

# Remove cached images
podman rmi $(podman images --format "{{.ID}}" | grep "192.168.123.1:5000")
```

## Troubleshooting

### Registry Not Accessible

1. Check if container is running:
   ```bash
   podman ps | grep local-registry
   ```

2. Check firewall rules:
   ```bash
   sudo firewall-cmd --list-ports
   sudo firewall-cmd --add-port=5000/tcp --permanent
   sudo firewall-cmd --reload
   ```

3. Test connectivity:
   ```bash
   curl -v http://192.168.123.1:5000/v2/_catalog
   ```

### Images Not Being Pulled from Cache

1. Verify Talos config has mirror settings:
   ```bash
   grep -A5 "mirrors:" talos-cluster/controlplane.yaml
   ```

2. Check that images exist in local registry:
   ```bash
   ./scripts/verify-local-registry.sh
   ```

3. Regenerate Talos configs if needed:
   ```bash
   ./scripts/talos-bootstrap/03-generate-configs.sh
   ```

### TLS/Certificate Errors

The local registry uses HTTP (not HTTPS). Ensure:
- `insecureSkipVerify: true` is set in Talos config
- VMs can reach the registry IP without TLS

## Integration with Cluster Components

### Cilium

Cilium images are pre-cached. When installing:
```bash
./scripts/k8s-components.sh --cni-cilium
```

Images are pulled from local registry automatically.

### MetalLB

MetalLB controller and speaker images are cached:
```bash
./scripts/k8s-components.sh --with-metallb
```

### Kubernetes Dashboard

Dashboard images are cached during population:
```bash
./scripts/talos-bootstrap/09-install-dashboard.sh
```

### Helm Charts

For Helm charts that pull images:
1. Add image references to `populate-local-registry.sh`
2. Run populate script before deploying chart
3. Configure Helm to use local registry if needed

## Best Practices

1. **Populate before bootstrap**: Always run `populate-local-registry.sh` before bootstrapping the cluster
2. **Verify configuration**: Use `verify-local-registry.sh` to ensure everything is set up correctly
3. **Keep cache updated**: Periodically re-run populate script to update image versions
4. **Monitor storage**: Registry images can consume significant disk space
5. **Backup important images**: Consider exporting critical images for disaster recovery

## Related Documentation

- [Network Setup](01-Network-setup.md)
- [Talos Configuration](03-Talos-Configuration.md)
- [Cilium Setup](05-Cilium-Setup.md)
- [MetalLB LoadBalancer](09-MetalLB-LoadBalancer.md)
- [Kubernetes Dashboard](08-Kubernetes-Dashboard.md)
