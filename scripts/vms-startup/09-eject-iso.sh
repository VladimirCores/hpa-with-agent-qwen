#!/bin/bash
# Step 09: Eject ISO and set disk boot
# Ejects ISO from all VMs and updates boot order to disk-only

echo "[9/11] Ejecting ISO and setting disk boot..."

# Get all IPs from libvirt network
mapfile -t VM_IPS < <(get_libvirt_ips "$NETWORK_NAME" "ipv4")

for vm_name in "$MASTER_NAME" $(for i in $(seq 1 $WORKER_COUNT); do echo "${WORKER_NAME_PREFIX}${i}"; done); do
    # Find VM with matching suffix
    ACTUAL_VM=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep -E "${vm_name}[^0-9]*\s" | awk '{print $2}' | head -1 || true)
    if [[ -n "$ACTUAL_VM" ]]; then
        # Get IP for this VM from the list
        VM_IP=""
        for ip in "${VM_IPS[@]}"; do
            VM_MAC=$(virsh -c "$LIBVIRT_URI" domifaddr "$ACTUAL_VM" 2>/dev/null | grep -v "^-" | awk '{print $2}' | head -1)
            if [[ -n "$VM_MAC" ]]; then
                LEASE_MAC=$(virsh -c "$LIBVIRT_URI" net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep "$ip" | awk '{print $2}')
                if [[ "$VM_MAC" == "$LEASE_MAC" ]]; then
                    VM_IP="$ip"
                    break
                fi
            fi
        done

        # Eject ISO from CDROM
        virsh -c "$LIBVIRT_URI" change-media-device "$ACTUAL_VM" --path hda --eject 2>/dev/null || true

        # Update boot order: disk first, cdrom removed
        XML=$(virsh -c "$LIBVIRT_URI" dumpxml "$ACTUAL_VM" 2>/dev/null)
        if echo "$XML" | grep -q "<boot dev='cdrom'/>"; then
            # Remove cdrom boot entry, keep only hd
            echo "$XML" | sed "/<boot dev='cdrom'\/>/d" | virsh -c "$LIBVIRT_URI" define /dev/stdin 2>/dev/null || true
        fi

        echo "    ✓ ISO ejected from $ACTUAL_VM"
    fi
done

echo "  ✓ ISO ejected, boot order set to disk-only"
echo ""
