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

# Check system resources
echo "  Checking system resources..."

# Calculate required resources
REQUIRED_MEM=$((MASTER_MEMORY + WORKER_MEMORY * WORKER_COUNT))
REQUIRED_CPU=$((MASTER_CPUS + WORKER_CPUS * WORKER_COUNT))
REQUIRED_DISK=20000  # 20GB minimum in MB

# Check available memory
AVAILABLE_MEM=$(free -m | awk '/^Mem:/{print $7}')
if [[ $AVAILABLE_MEM -lt $REQUIRED_MEM ]]; then
    echo "  ✗ Insufficient memory: Available ${AVAILABLE_MEM}MB < Required ${REQUIRED_MEM}MB"
    echo "    Required breakdown:"
    echo "      - Master: ${MASTER_MEMORY}MB"
    echo "      - Workers (${WORKER_COUNT}x): $((WORKER_MEMORY * WORKER_COUNT))MB"
    echo "    Remediation:"
    echo "      - Close other applications to free memory"
    echo "      - Reduce MASTER_MEMORY or WORKER_MEMORY in .env"
    echo "      - Reduce WORKER_COUNT in .env"
    exit 1
fi
echo "  ✓ Memory: ${AVAILABLE_MEM}MB available (required: ${REQUIRED_MEM}MB)"

# Check disk space
AVAILABLE_DISK=$(df -m /var/lib/libvirt 2>/dev/null | awk 'NR==2{print $4}' || df -m / | awk 'NR==2{print $4}')
if [[ $AVAILABLE_DISK -lt $REQUIRED_DISK ]]; then
    echo "  ✗ Insufficient disk space: Available ${AVAILABLE_DISK}MB < Required ${REQUIRED_DISK}MB (20GB)"
    echo "    Remediation:"
    echo "      - Free up disk space on /var/lib/libvirt or root partition"
    echo "      - Remove unused VMs or images"
    echo "      - Ensure at least 20GB free for VM disks"
    exit 1
fi
echo "  ✓ Disk: ${AVAILABLE_DISK}MB available (required: ${REQUIRED_DISK}MB)"

# Check CPU cores
CPU_CORES=$(nproc)
if [[ $CPU_CORES -lt $REQUIRED_CPU ]]; then
    echo "  ✗ Insufficient CPUs: Available ${CPU_CORES} < Required ${REQUIRED_CPU}"
    echo "    Required breakdown:"
    echo "      - Master: ${MASTER_CPUS} cores"
    echo "      - Workers (${WORKER_COUNT}x): $((WORKER_CPUS * WORKER_COUNT)) cores"
    echo "    Remediation:"
    echo "      - Reduce MASTER_CPUS or WORKER_CPUS in .env"
    echo "      - Reduce WORKER_COUNT in .env"
    exit 1
fi
echo "  ✓ CPUs: ${CPU_CORES} cores available (required: ${REQUIRED_CPU})"

# Check libvirt network exists
echo "  Checking libvirt network configuration..."
if ! virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" &>/dev/null; then
    echo "  ✗ Libvirt network '$NETWORK_NAME' not found"
    echo "    Remediation:"
    echo "      - Run: ./scripts/prepare-network.sh"
    echo "      - Or create network manually with virsh"
    exit 1
fi
echo "  ✓ Libvirt network '$NETWORK_NAME' exists"

# Check if network is active
NETWORK_STATE=$(virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null | grep "State:" | awk '{print $2}')
if [[ "$NETWORK_STATE" != "active" ]]; then
    echo "  ✗ Libvirt network '$NETWORK_NAME' is not active (state: $NETWORK_STATE)"
    echo "    Remediation:"
    echo "      - Run: virsh -c $LIBVIRT_URI net-start $NETWORK_NAME"
    echo "      - Or run: ./scripts/prepare-network.sh"
    exit 1
fi
echo "  ✓ Libvirt network '$NETWORK_NAME' is active"

echo ""
echo "  ✓ All prerequisites met"
echo ""
