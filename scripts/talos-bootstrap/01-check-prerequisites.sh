#!/bin/bash
# =============================================================================
# Step 01: Check Prerequisites
# =============================================================================
# Checks talosctl, kubectl, and verifies all VMs are running.
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

echo "[1/9] Checking prerequisites..."

# Check talosctl
if ! command -v talosctl &>/dev/null; then
    echo "ERROR: talosctl not found"
    echo "  Install: curl -L -o talosctl https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-amd64"
    echo "           chmod +x talosctl && sudo mv talosctl /usr/local/bin/"
    exit 1
fi
echo "  ✓ talosctl: $(talosctl version --short 2>/dev/null || echo 'installed')"

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo "  WARNING: kubectl not found"
    echo "    Install: curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    KUBECTL_AVAILABLE=false
else
    echo "  ✓ kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
    KUBECTL_AVAILABLE=true
fi

# Check VMs are running
echo "  Checking VMs..."
VM_COUNT=0
EXPECTED_VMS=$((1 + WORKER_COUNT))

# Find master VM (handles Vagrant prefix)
MASTER_VM=""
WORKER_VMS=()

while IFS= read -r line; do
    VM_NAME=$(echo "$line" | awk '{print $2}')
    if [[ "$VM_NAME" == *"$MASTER_NAME" ]]; then
        MASTER_VM="$VM_NAME"
        break
    fi
done < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -v "^ Id")

# Find worker VMs
for i in $(seq 1 $WORKER_COUNT); do
    while IFS= read -r line; do
        VM_NAME=$(echo "$line" | awk '{print $2}')
        if [[ "$VM_NAME" == *"${WORKER_NAME_PREFIX}${i}" ]]; then
            WORKER_VMS+=("$VM_NAME")
            break
        fi
    done < <(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -v "^ Id")
done

# Check master
if [[ -n "$MASTER_VM" ]]; then
    STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$MASTER_VM" 2>/dev/null | grep "State:" | awk '{print $2}')
    if [[ "$STATE" == "running" ]]; then
        echo "    ✓ $MASTER_VM: running"
        VM_COUNT=$((VM_COUNT + 1))
    else
        echo "    ✗ $MASTER_VM: $STATE (not running)"
    fi
else
    echo "    ✗ $MASTER_NAME: not found"
fi

# Check workers
for WORKER_VM in "${WORKER_VMS[@]}"; do
    STATE=$(virsh -c "$LIBVIRT_URI" dominfo "$WORKER_VM" 2>/dev/null | grep "State:" | awk '{print $2}')
    if [[ "$STATE" == "running" ]]; then
        echo "    ✓ $WORKER_VM: running"
        VM_COUNT=$((VM_COUNT + 1))
    else
        echo "    ✗ $WORKER_VM: $STATE (not running)"
    fi
done

if (( VM_COUNT != EXPECTED_VMS )); then
    echo "ERROR: Not all VMs are running. Expected $EXPECTED_VMS, got $VM_COUNT"
    echo "  Start VMs with: ./scripts/vms-startup.sh"
    exit 1
fi

echo ""
echo "  ✓ All prerequisites met"
echo ""
