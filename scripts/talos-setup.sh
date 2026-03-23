CONTROL_PLANE_IP=("10.0.0.10")
WORKER_IP=("10.0.0.11" "10.0.0.12")
YOUR_ENDPOINT=10.0.0.1
CLUSTER_NAME=talos-cluster-demo

talosctl gen config --with-secrets secrets.yaml --talos-version v1.12 $CLUSTER_NAME https://$YOUR_ENDPOINT:6443 -f
