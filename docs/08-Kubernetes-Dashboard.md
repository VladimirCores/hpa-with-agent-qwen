# Kubernetes Dashboard Setup

The Kubernetes Dashboard is automatically installed during the bootstrap process (Step 09).

## Access

### Web URL

The dashboard is exposed via **NodePort 30443** on all cluster nodes:

| Node | URL |
|------|-----|
| Master | `https://192.168.123.10:30443` |
| Worker-1 | `https://192.168.123.20:30443` |
| Worker-2 | `https://192.168.123.21:30443` |

> **Note:** Accept the self-signed certificate warning in your browser.

### Authentication

Login with the admin token:

```bash
# Token file location
cat talos-cluster/dashboard-admin-token.txt

# Or generate new token
kubectl -n kubernetes-dashboard create token admin-user
```

## What Gets Installed

1. **Kubernetes Dashboard** - Official web UI for cluster management
2. **Metrics Scraper** - Collects metrics for dashboard display
3. **Admin User** - ServiceAccount with `cluster-admin` ClusterRoleBinding

## Manual Installation

If you need to reinstall the dashboard:

```bash
# Remove existing installation
kubectl delete -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
kubectl delete clusterrolebinding admin-user
kubectl delete serviceaccount admin-user -n kubernetes-dashboard
kubectl delete namespace kubernetes-dashboard

# Run bootstrap step 9 only
bash scripts/talos-bootstrap/09-install-dashboard.sh
```

## Troubleshooting

### Dashboard pods not running

```bash
# Check pod status
kubectl get pods -n kubernetes-dashboard

# Check pod logs
kubectl logs -n kubernetes-dashboard -l k8s-app=kubernetes-dashboard
```

### Cannot access dashboard URL

```bash
# Verify service
kubectl get svc -n kubernetes-dashboard

# Verify NodePort is configured
kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}'

# Check if port is accessible (from host)
curl -k https://192.168.123.10:30443
```

### Token expired or invalid

```bash
# Generate new token
kubectl -n kubernetes-dashboard create token admin-user

# Update token file
kubectl -n kubernetes-dashboard create token admin-user > talos-cluster/dashboard-admin-token.txt
```

## Features

The Kubernetes Dashboard provides:

- **Cluster Overview** - Node status, resource usage, health
- **Workload Management** - Deployments, Pods, ReplicaSets, StatefulSets
- **Service Discovery** - Services, Endpoints, Ingress
- **Storage** - PersistentVolumes, PersistentVolumeClaims, StorageClasses
- **Configuration** - ConfigMaps, Secrets
- **Namespace Management** - Switch between namespaces
- **Real-time Logs** - View pod logs in real-time
- **Exec into Pods** - Run commands inside containers
- **Resource Metrics** - CPU/Memory usage (if metrics-server installed)
