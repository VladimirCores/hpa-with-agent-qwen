#!/bin/bash
# =============================================================================
# Step 08b: Configure UEFI Firmware for Talos VMs
# =============================================================================
# This step configures UEFI firmware for Talos VMs if not already configured.
# Talos v1.12.x requires UEFI firmware to boot properly.
#
# What this step does:
# 1. Checks if VMs have UEFI loader configured
# 2. If not, stops VMs and reconfigures with UEFI
# 3. Adds NVRAM storage for UEFI variables
# 4. Configures boot order (CDROM first, then disk)
# 5. Restarts VMs with UEFI enabled
# =============================================================================

# Source common setup
STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STEP_DIR/00-setup.sh"

# Detect QEMU machine type dynamically
detect_machine_type() {
    local machine
    machine=$(virsh -c "$LIBVIRT_URI" capabilities 2>/dev/null | grep -m1 "<machine canonical=" | sed 's/.*canonical='"'"'\([^'"'"']*\)'"'"'.*/\1/')
    echo "${machine:-pc-i440fx-10.1}"  # Fallback if detection fails
}
QEMU_MACHINE="$(detect_machine_type)"

# Configuration
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"
NVRAM_DIR="/var/lib/libvirt/qemu/nvram"
# Convert ISO_PATH to absolute path
if [[ -f "$TALOS_IMAGE_PATH" ]]; then
    ISO_PATH="$(cd "$(dirname "$TALOS_IMAGE_PATH")" && pwd)/$(basename "$TALOS_IMAGE_PATH")"
else
    ISO_PATH="${TALOS_IMAGE_PATH:-./metal-amd64.iso}"
fi

echo "[8b/12] Configuring UEFI Firmware for Talos VMs..."
echo ""

# Ensure NVRAM directory exists
echo "  Ensuring NVRAM directory exists..."
if ! run_sudo mkdir -p "$NVRAM_DIR" 2>/dev/null; then
    echo "  WARNING: Could not create NVRAM directory, continuing anyway..."
fi
run_sudo chown qemu:kvm "$NVRAM_DIR" 2>/dev/null || true
run_sudo chmod 755 "$NVRAM_DIR" 2>/dev/null || true
echo "  ✓ NVRAM directory ready"
echo ""

# Function to check if VM has UEFI configured
check_uefi_configured() {
    local vm_name="$1"
    local xml_output
    # Check for UEFI loader (pflash type) in os section
    xml_output=$(virsh -c "$LIBVIRT_URI" dumpxml "$vm_name" 2>/dev/null)
    if echo "$xml_output" | grep -A5 "<os>" | grep -q 'loader.*pflash'; then
        return 0
    else
        return 1
    fi
}

# Function to configure UEFI for a VM
configure_uefi() {
    local vm_name="$1"
    local memory_mb="$2"
    local vcpus="$3"
    local disk_path="$4"
    local nvram_path="$NVRAM_DIR/${vm_name}_VARS.fd"
    local use_iso="${5:-false}"  # Whether to use ISO boot
    
    echo "  Configuring UEFI for: $vm_name"
    
    # Stop VM if running
    if virsh -c "$LIBVIRT_URI" domstate "$vm_name" 2>/dev/null | grep -q "running"; then
        echo "    Stopping VM..."
        virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true
        sleep 2
    fi
    
    # Copy OVMF_VARS if template exists
    if [[ -f "$OVMF_VARS" ]] && [[ ! -f "$nvram_path" ]]; then
        echo "    Creating NVRAM storage..."
        run_sudo cp "$OVMF_VARS" "$nvram_path" 2>/dev/null || true
        run_sudo chown qemu:kvm "$nvram_path" 2>/dev/null || true
    fi
    
    # Create VM XML with UEFI
    local temp_xml=$(mktemp)
    
    if [[ "$use_iso" == "true" ]]; then
        # ISO mode: boot from CDROM first, then disk
        cat > "$temp_xml" << VMXML
<domain type="kvm">
  <name>$vm_name</name>
  <memory unit="KiB">${memory_mb}024</memory>
  <vcpu>$vcpus</vcpu>
  <os>
    <type arch="x86_64" machine="$QEMU_MACHINE">hvm</type>
    <loader readonly="yes" type="pflash" secure="no">$OVMF_CODE</loader>
    <nvram>$nvram_path</nvram>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="$ISO_PATH"/>
      <target dev="hda" bus="ide"/>
      <boot order="1"/>
      <readonly/>
    </disk>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" cache="none"/>
      <source file="$disk_path"/>
      <target dev="vda" bus="virtio"/>
      <boot order="2"/>
    </disk>
    <interface type="network">
      <source network="$NETWORK_NAME"/>
      <model type="virtio"/>
    </interface>
    <console type="pty"/>
    <graphics type="vnc" port="-1" autoport="yes" listen="127.0.0.1"/>
  </devices>
</domain>
VMXML
    else
        # Raw image mode: boot from disk only
        cat > "$temp_xml" << VMXML
<domain type="kvm">
  <name>$vm_name</name>
  <memory unit="KiB">${memory_mb}024</memory>
  <vcpu>$vcpus</vcpu>
  <os>
    <type arch="x86_64" machine="$QEMU_MACHINE">hvm</type>
    <loader readonly="yes" type="pflash" secure="no">$OVMF_CODE</loader>
    <nvram>$nvram_path</nvram>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" cache="none"/>
      <source file="$disk_path"/>
      <target dev="vda" bus="virtio"/>
      <boot order="1"/>
    </disk>
    <interface type="network">
      <source network="$NETWORK_NAME"/>
      <model type="virtio"/>
    </interface>
    <console type="pty"/>
    <graphics type="vnc" port="-1" autoport="yes" listen="127.0.0.1"/>
  </devices>
</domain>
VMXML
    fi
    
    # Undefine VM (with nvram if exists)
    echo "    Reconfiguring VM..."
    virsh -c "$LIBVIRT_URI" undefine "$vm_name" --nvram 2>/dev/null || \
    virsh -c "$LIBVIRT_URI" undefine "$vm_name" 2>/dev/null || true
    
    # Define with new XML
    if virsh -c "$LIBVIRT_URI" define "$temp_xml" 2>/dev/null; then
        echo "    ✓ UEFI configured"
        rm -f "$temp_xml"
        return 0
    else
        echo "    ✗ Failed to configure UEFI"
        rm -f "$temp_xml"
        return 1
    fi
}

# Track if any VMs were reconfigured
RECONFIGURED=0
UEFI_ALREADY=0

# Determine boot mode (ISO or raw image)
USE_ISO="false"
if [[ "${USE_RAW_IMAGE:-false}" != "true" ]]; then
    USE_ISO="true"
    echo "  Boot mode: ISO installation"
else
    echo "  Boot mode: Raw disk image"
fi
echo ""

# Process each VM
echo "Checking VM UEFI configuration..."
echo ""

# VM names include vagrant-libvirt prefix (derived from project directory)
VAGRANT_PREFIX="$(basename "$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")")_"
MASTER_VM_NAME="${VAGRANT_PREFIX}${MASTER_NAME}"
MASTER_DISK_PATH="$POOL_PATH/${MASTER_VM_NAME}-vda.qcow2"

if check_uefi_configured "$MASTER_VM_NAME"; then
    echo "  $MASTER_VM_NAME: UEFI already configured ✓"
    UEFI_ALREADY=$((UEFI_ALREADY + 1))
else
    echo "  $MASTER_VM_NAME: UEFI not configured"
    if configure_uefi "$MASTER_VM_NAME" "$MASTER_MEMORY" "$MASTER_CPUS" "$MASTER_DISK_PATH" "$USE_ISO"; then
        RECONFIGURED=$((RECONFIGURED + 1))
    fi
fi

# Worker VMs
for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
    WORKER_VM_NAME="${VAGRANT_PREFIX}${WORKER_NAME}"
    WORKER_DISK_PATH="$POOL_PATH/${WORKER_VM_NAME}-vda.qcow2"
    
    if check_uefi_configured "$WORKER_VM_NAME"; then
        echo "  $WORKER_VM_NAME: UEFI already configured ✓"
        UEFI_ALREADY=$((UEFI_ALREADY + 1))
    else
        echo "  $WORKER_VM_NAME: UEFI not configured"
        if configure_uefi "$WORKER_VM_NAME" "$WORKER_MEMORY" "$WORKER_CPUS" "$WORKER_DISK_PATH" "$USE_ISO"; then
            RECONFIGURED=$((RECONFIGURED + 1))
        fi
    fi
done

echo ""

# Start VMs if any were reconfigured
if [[ $RECONFIGURED -gt 0 ]]; then
    echo "Starting VMs with UEFI firmware..."
    echo ""

    # Master
    echo "  Starting $MASTER_VM_NAME..."
    if virsh -c "$LIBVIRT_URI" start "$MASTER_VM_NAME" 2>/dev/null; then
        echo "    ✓ Started"
    else
        echo "    ✗ Failed to start"
    fi

    # Workers
    for i in $(seq 1 $WORKER_COUNT); do
        WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
        WORKER_VM_NAME="${VAGRANT_PREFIX}${WORKER_NAME}"
        echo "  Starting $WORKER_VM_NAME..."
        if virsh -c "$LIBVIRT_URI" start "$WORKER_VM_NAME" 2>/dev/null; then
            echo "    ✓ Started"
        else
            echo "    ✗ Failed to start"
        fi
    done

    echo ""
    echo "  Waiting for VMs to boot..."
    sleep 10
else
    echo "No VMs needed reconfiguration ($UEFI_ALREADY already configured)"
fi

# Verify UEFI configuration
echo "Verifying UEFI configuration..."
echo ""

UEFI_VERIFIED=0
for vm_name in "$MASTER_VM_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${VAGRANT_PREFIX}${WORKER_NAME_PREFIX}${i}"; done); do
    if check_uefi_configured "$vm_name"; then
        echo "  $vm_name: UEFI verified ✓"
        UEFI_VERIFIED=$((UEFI_VERIFIED + 1))
    else
        echo "  $vm_name: UEFI not configured ✗"
    fi
done

echo ""

# Summary
if [[ $UEFI_VERIFIED -eq $((1 + WORKER_COUNT)) ]]; then
    echo "  ✓ All VMs have UEFI firmware configured"
    
    if [[ $RECONFIGURED -gt 0 ]]; then
        echo ""
        echo "  Note: VMs were reconfigured with UEFI."
        echo "  Talos will boot from ISO and install to disk."
        echo "  This may take 5-10 minutes."
    fi
else
    echo "  WARNING: Some VMs may not have UEFI configured correctly"
fi

echo ""
echo "  ✓ Completed"
echo ""
