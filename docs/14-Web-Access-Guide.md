# Web Access Guide

## Current Status (2026-04-06)

| Service | URL | Status | Notes |
|---------|-----|--------|-------|
| **Kubernetes Dashboard** | https://192.168.123.201 | ✅ **WORKING** | Fully accessible |
| **Hubble UI** | http://192.168.123.200 | ⚠️ Not Working | Frontend container compatibility issue |

---

## ✅ Kubernetes Dashboard - Access Instructions

### URL
```
https://192.168.123.201
```

### Login Token

**Generate 24-hour token:**
```bash
kubectl --kubeconfig talos-cluster/kubeconfig -n kubernetes-dashboard create token admin-user --duration=24h
```

**Or use saved token (from bootstrap):**
```bash
cat talos-cluster/dashboard-admin-token.txt
```

### Steps to Access

1. **Open browser:** https://192.168.123.201
2. **Accept certificate warning:** Click "Advanced" → "Proceed to 192.168.123.201 (unsafe)"
3. **Select "Token"** authentication method
4. **Paste the token** from the command above
5. **Click "Sign in"**

### Verification

Test from command line:
```bash
# Should return HTTP 200 and HTML content
curl -sk https://192.168.123.201 | head -20
```

Expected output:
```html
<!DOCTYPE html><html lang="en" dir="ltr">
  <title>Kubernetes Dashboard</title>
  ...
```

---

## ⚠️ Hubble UI - Issue Status

### Problem
Hubble UI frontend container (nginx) crashes immediately on Talos Linux due to port binding compatibility issues with the container runtime.

### Workaround: Use Cilium CLI Instead

While Hubble UI is not accessible via web, you can use the Cilium CLI for network observability:

```bash
# Install Cilium CLI (if not already installed)
cilium status

# Observe network flows
cilium observe

# Monitor specific pod
cilium observe --pod default/my-app

# View policy decisions
cilium observe --verdict DROPPED
```

### Alternative: Port-Forward Backend API

If you need to access Hubble data, you can query the backend API directly:

```bash
# Port-forward to backend
kubectl --kubeconfig talos-cluster/kubeconfig port-forward -n kube-system deployment/hubble-ui 8090:8090

# Query API
curl http://localhost:8090/api/v1/flows
```

---

## Why MetalLB LoadBalancer Works

Your cluster setup:
- Host has `virbr1` interface at `192.168.123.1/24`
- VMs are on the same `192.168.123.0/24` network
- MetalLB Layer 2 mode announces service IPs via ARP
- Host can reach these IPs directly

**This is different from libvirt NAT networks** where the host cannot reach VM IPs directly. Your setup uses a bridged/virtual network that allows host-to-VM communication.

---

## Troubleshooting

### Dashboard Not Accessible

1. **Check pod status:**
   ```bash
   kubectl --kubeconfig talos-cluster/kubeconfig get pods -n kubernetes-dashboard
   ```

2. **Check service:**
   ```bash
   kubectl --kubeconfig talos-cluster/kubeconfig get svc kubernetes-dashboard -n kubernetes-dashboard
   # Should show EXTERNAL-IP: 192.168.123.201
   ```

3. **Test connectivity:**
   ```bash
   ping -c 2 192.168.123.201
   curl -sk https://192.168.123.201
   ```

4. **Restart if needed:**
   ```bash
   kubectl --kubeconfig talos-cluster/kubeconfig -n kubernetes-dashboard rollout restart deployment kubernetes-dashboard
   ```

### Token Expired or Invalid

Generate a new token:
```bash
kubectl --kubeconfig talos-cluster/kubeconfig -n kubernetes-dashboard create token admin-user --duration=24h
```

---

## Summary

✅ **Kubernetes Dashboard**: Fully operational at https://192.168.123.201  
⚠️ **Hubble UI**: Known issue with frontend container on Talos  
✅ **MetalLB**: Successfully assigning external IPs  
✅ **All other components**: Operational  

For HPA studies, the Kubernetes Dashboard provides sufficient cluster management and monitoring capabilities.
