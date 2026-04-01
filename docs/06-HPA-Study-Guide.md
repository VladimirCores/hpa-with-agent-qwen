# HPA Study Guide - Horizontal Pod Autoscaling with Talos Kubernetes

This guide provides examples and exercises for studying Horizontal Pod Autoscaling (HPA) in the Talos Kubernetes cluster.

## Prerequisites

- Talos Kubernetes cluster with Cilium CNI
- metrics-server installed (optional, for resource-based HPA)
- kubectl configured

## Quick Setup

```bash
# 1. Start the cluster
./scripts/vms-startup.sh

# 2. Bootstrap Talos
./scripts/talos-bootstrap.sh

# 3. Install Cilium CNI
./scripts/k8s-components.sh --cni-cilium

# 4. (Optional) Install metrics-server for CPU/memory-based HPA
./scripts/k8s-components.sh -m
```

## HPA Types

### 1. Resource-Based HPA (CPU/Memory)

Requires metrics-server to be installed.

```bash
# Deploy a sample application
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app: nginx
  replicas: 2
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF

# Create HPA (autoscale based on CPU)
kubectl autoscale deployment nginx-deployment \
  --cpu-percent=50 \
  --min=2 \
  --max=10

# Check HPA status
kubectl get hpa

# Watch HPA in action
kubectl get hpa -w
```

### 2. Custom Metrics HPA

Using Prometheus Adapter for custom metrics (advanced).

### 3. External Metrics HPA

Using external metrics providers.

## Load Testing

### Generate Load with BusyBox

```bash
# Create a load generator pod
kubectl run -i --tty load-generator --image=busybox:1.36 --restart=Never -- /bin/sh

# Inside the pod, run:
while true; do wget -q -O- http://nginx-service; done
```

### Generate Load with hey (HTTP Load Generator)

```bash
# Install hey
go install github.com/rakyll/hey@latest

# Generate load
hey -z 10m -c 10 http://<nginx-service-ip>/
```

### Generate Load with k6

```bash
# Install k6
sudo apt install k6  # or download from https://k6.io/

# Create load test script
cat > load-test.js <<EOF
import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  vus: 10,
  duration: '5m',
};

export default function () {
  http.get('http://<nginx-service-ip>/');
  sleep(1);
}
EOF

# Run load test
k6 run load-test.js
```

## Monitoring HPA

### Watch Pod Scaling

```bash
# Watch pods being created/terminated
kubectl get pods -w

# Watch deployment status
kubectl get deployment nginx-deployment -w
```

### Check HPA Events

```bash
# Describe HPA for events
kubectl describe hpa nginx-deployment

# Watch events
kubectl get events --field-selector involvedObject.kind=HorizontalPodAutoscaler -w
```

### Check Metrics

```bash
# Check node metrics
kubectl top nodes

# Check pod metrics
kubectl top pods -n default
```

## HPA Configuration Examples

### Basic CPU-Based HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

### Multi-Metric HPA (CPU and Memory)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
      selectPolicy: Max
```

### HPA with Custom Metrics

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Pods
    pods:
      metric:
        name: packets-per-second
      target:
        type: AverageValue
        averageValue: 1k
```

## Exercises

### Exercise 1: Basic HPA

1. Deploy the nginx application
2. Create an HPA with min=2, max=5, CPU=50%
3. Generate load and observe scaling
4. Remove load and observe scale-down

### Exercise 2: HPA Behavior Tuning

1. Deploy an application with aggressive scale-up
2. Configure scale-down stabilization window
3. Test rapid load changes
4. Observe behavior differences

### Exercise 3: Multi-Metric HPA

1. Deploy an application with CPU and memory limits
2. Create HPA with both CPU and memory targets
3. Generate CPU-intensive load
4. Generate memory-intensive load
5. Observe which metric triggers scaling

### Exercise 4: HPA with Cilium Observability

1. Enable Hubble in Cilium
2. Deploy application with HPA
3. Use Hubble to observe traffic patterns during scaling
4. Correlate network traffic with scaling events

```bash
# Enable Hubble
cilium hubble enable

# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8080:80

# Open http://localhost:8080
```

## Troubleshooting

### HPA Not Scaling

```bash
# Check if metrics are available
kubectl top pods

# Check HPA events
kubectl describe hpa <hpa-name>

# Check if metrics-server is running
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

### Metrics Not Available

```bash
# Restart metrics-server
kubectl rollout restart deployment metrics-server -n kube-system

# Wait for metrics to populate (takes 1-2 minutes)
sleep 60
kubectl top nodes
```

### Pods Not Scaling Down

Check HPA behavior configuration:
```bash
kubectl get hpa <hpa-name> -o yaml
```

Look for `behavior.scaleDown.stabilizationWindowSeconds`.

## Best Practices

1. **Set Resource Requests**: HPA needs resource requests to calculate utilization
2. **Use Stabilization Windows**: Prevent flapping during rapid load changes
3. **Monitor Multiple Metrics**: Use both CPU and memory for balanced scaling
4. **Test Scaling Behavior**: Verify scale-up and scale-down work as expected
5. **Set Appropriate Limits**: Ensure maxReplicas doesn't exceed cluster capacity

## Resources

- [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/horizontal-pod-autoscaler-v2/)
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
- [Cilium Documentation](https://docs.cilium.io/)
