#!/bin/bash
# Enable UEFI Firmware for Talos VMs

LIBVIRT_URI="qemu:///system"
NVRAM_DIR="/var/lib/libvirt/qemu/nvram"

echo "=== Enable UEFI Firmware for Talos VMs ==="
echo ""

# Ensure NVRAM directory exists
sudo mkdir -p "$NVRAM_DIR"
sudo chown qemu:kvm "$NVRAM_DIR"
echo "NVRAM directory ready"
echo ""

# Process each VM
for vm_name in with-agent-qwen_talos-master with-agent-qwen_talos-worker-1 with-agent-qwen_talos-worker-2; do
    echo "Processing: $vm_name"
    
    # Stop VM if running
    virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true
    sleep 1
    
    # Export and modify XML
    temp_xml="/tmp/${vm_name}_uefi.xml"
    virsh -c "$LIBVIRT_URI" dumpxml "$vm_name" > "$temp_xml" 2>/dev/null
    
    # Replace os section using sed
    sed -i '/<os>/,/<\/os>/d' "$temp_xml"
    sed -i '/<name>'"$vm_name"'<\/a>/a\  <os>\n    <type arch='"'"'x86_64'"'"' machine='"'"'pc-i440fx-10.1'"'"'>hvm</type>\n    <loader readonly='"'"'yes'"'"' type='"'"'pflash'"'"' secure='"'"'no'"'"'>/usr/share/OVMF/OVMF_CODE.fd</loader>\n    <nvram>'"$NVRAM_DIR"'/'"$vm_name"'_VARS.fd</nvram>\n    <boot dev='"'"'hd'"'"'/>\n  </os>' "$temp_xml"
    
    # Undefine and redefine
    virsh -c "$LIBVIRT_URI" undefine "$vm_name" 2>/dev/null || true
    if virsh -c "$LIBVIRT_URI" define "$temp_xml" 2>/dev/null; then
        echo "  ✓ UEFI enabled"
    else
        echo "  ✗ Failed"
    fi
    
    rm -f "$temp_xml"
done

echo ""
echo "=== Complete ==="
echo "Start VMs and wait for Talos to boot with UEFI"
