#!/bin/bash
# =============================================================================
# Start Talos Cluster VMs - Structured Step-by-Step Execution
# =============================================================================
# This script starts all Talos cluster VMs with proper cleanup and verification.
# Each step executes sequentially and must complete successfully before continuing.
# Supports both ISO-based installation and raw disk image provisioning.
# =============================================================================

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
STEPS_DIR="$SCRIPT_DIR/vms-startup"

# Source shared logging library
source "$PROJECT_ROOT/scripts/logging.sh"

# Source .env file
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    log INFO "Loading configuration from .env file..."

    # First, check for common syntax issues before sourcing
    env_errors=()
    line_num=0

    # Check for unquoted angle brackets (common in ROOT_PASSWORD)
    # Only check non-comment lines that contain '=' and extract the value part
    while IFS=: read -r ln fullline; do
        # Extract just the value part after '='
        value_part="${fullline#*=}"
        # Check if value (before any comment) has unquoted angle brackets
        value_before_comment="${value_part%%#*}"
        # Check if it's already quoted
        if [[ "$value_before_comment" == *"<"*">"* ]] && [[ "$value_before_comment" != \"*\" ]] && [[ "$value_before_comment" != \'*\' ]]; then
            env_errors+=("Line $ln: Unquoted angle brackets detected. Variables with special characters like < > must be quoted.")
            env_errors+=("         Problem: $fullline")
            env_errors+=("         Fix: Add quotes around the value, e.g., VAR=\"<value>\"")
        fi
    done < <(grep -n '^[^#]*=' "$PROJECT_ROOT/.env" 2>/dev/null || true)

    # Check for unquoted spaces in values (only non-comment lines with '=')
    while IFS=: read -r ln fullline; do
        # Extract just the value part after '='
        value_part="${fullline#*=}"
        # Check if value (before any comment) has unquoted spaces
        value_before_comment="${value_part%%#*}"
        # Trim trailing whitespace
        value_before_comment="$(echo "$value_before_comment" | sed 's/[[:space:]]*$//')"
        # Check for unquoted spaces (value contains space but isn't quoted)
        if [[ "$value_before_comment" == *" "* ]] && [[ "$value_before_comment" != \"*\" ]] && [[ "$value_before_comment" != \'*\' ]]; then
            env_errors+=("Line $ln: Unquoted spaces detected in value. Values with spaces must be quoted.")
            env_errors+=("         Problem: $fullline")
            env_errors+=("         Fix: Add quotes around the value, e.g., VAR=\"value with spaces\"")
        fi
    done < <(grep -n '^[^#]*=' "$PROJECT_ROOT/.env" 2>/dev/null || true)

    if [[ ${#env_errors[@]} -gt 0 ]]; then
        log ERROR "Syntax issues detected in .env file"
        echo ""
        for error in "${env_errors[@]}"; do
            log ERROR "$error"
        done
        echo ""
        log WARN "Common causes:"
        echo "  • ROOT_PASSWORD contains unquoted special characters like < or >"
        echo "  • Other variables have unquoted spaces or special characters"
        echo ""
        log WARN "Solution:"
        echo "  Edit .env and quote values with special characters:"
        echo "    ROOT_PASSWORD=\"<CHANGE_ME_SECURE_PASSWORD>\""
        echo ""
        exit 1
    fi

    # Source the file if no errors found
    set -a
    source "$PROJECT_ROOT/.env"
    set +a

    # Validate critical variables
    if [[ -z "${ROOT_PASSWORD:-}" ]]; then
        log WARN "ROOT_PASSWORD is not set in .env"
        echo "  This may cause authentication issues later."
        echo "  Consider setting ROOT_PASSWORD in your .env file."
        echo ""
    else
        log OK "ROOT_PASSWORD is configured"
    fi

    log OK "Configuration loaded successfully"
    echo ""
else
    log ERROR ".env file not found in $PROJECT_ROOT"
    echo ""
    echo "Solution:"
    echo "  1. Copy the example file: cp .env.example .env"
    echo "  2. Edit .env and configure all required variables"
    echo "  3. Pay special attention to quoting values with special characters"
    echo "     Example: ROOT_PASSWORD=\"<your_password>\""
    echo ""
    exit 1
fi

# Export all variables for subprocesses
export NETWORK_NAME MASTER_NAME MASTER_IP WORKER_COUNT
export WORKER_NAME_PREFIX WORKER_IP_BASE STORAGE_POOL LIBVIRT_URI
export SKIP_CLEANUP FORCE_RESET VERBOSE CLUSTER_NAME TALOS_IMAGE_URL TALOS_IMAGE_PATH
export USE_RAW_IMAGE TALOS_RAW_IMAGE_PATH TALOS_RAW_IMAGE_COMPRESSED
export SUDO_USER MASTER_DISK WORKER_DISK FORWARD_MODE

# Set POOL_PATH if not defined in .env
POOL_PATH="${POOL_PATH:-$PROJECT_ROOT/.vagrant/storage-pool}"
export POOL_PATH

# Parse arguments
SKIP_CLEANUP=false
FORCE_RESET=false
VERBOSE=false

# VM name prefix (derived from project directory name, used by vagrant-libvirt)
VM_PREFIX="$(basename "$PROJECT_ROOT")_"

while getopts "sfv" opt; do
    case $opt in
        s) SKIP_CLEANUP=true ;;
        f) FORCE_RESET=true ;;
        v) VERBOSE=true ;;
        *) echo "Usage: $0 [-s] [-f] [-v]"
           echo "  -s  Skip cleanup (start without stopping existing VMs)"
           echo "  -f  Force reset (destroy VMs and disks, fresh start)"
           echo "  -v  Verbose output (detailed logging)"
           exit 1 ;;
    esac
done

# =============================================================================
# Helper Functions
# =============================================================================

run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_script="$3"
    shift 3

    log STEP "Step $step_num: $step_name"

    if bash "$step_script" "$@"; then
        log OK "$step_name completed"
        return 0
    else
        log ERROR "$step_name failed"
        echo ""
        log ERROR "Startup failed at step $step_num: $step_name"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check the error message above"
        echo "  2. Review logs in startup.log"
        echo "  3. Run with -v for verbose output"
        echo "  4. Fix the issue and re-run: $0"
        echo ""
        exit 1
    fi
}

verify_step() {
    local step_name="$1"
    local verify_cmd="$2"

    log INFO "Verifying: $step_name..."

    if eval "$verify_cmd" > /dev/null 2>&1; then
        log OK "Verification passed: $step_name"
        return 0
    else
        log ERROR "Verification failed: $step_name"
        return 1
    fi
}

# =============================================================================
# Main Script
# =============================================================================

log HEADER "Talos Cluster VM Startup"

log INFO "Configuration:"
log INFO "  LIBVIRT_URI:    $LIBVIRT_URI"
log INFO "  NETWORK_NAME:   $NETWORK_NAME"
log INFO "  FORWARD_MODE:   ${FORWARD_MODE:-nat}"
log INFO "  MASTER_NAME:    $MASTER_NAME ($MASTER_IP)"
log INFO "  WORKER_COUNT:   $WORKER_COUNT"
log INFO "  USE_RAW_IMAGE:  ${USE_RAW_IMAGE:-false}"
log INFO "  STORAGE_POOL:   $STORAGE_POOL"
log INFO "  POOL_PATH:      ${POOL_PATH:-auto}"
log INFO ""
log INFO "Options:"
log INFO "  SKIP_CLEANUP:   $SKIP_CLEANUP"
log INFO "  FORCE_RESET:    $FORCE_RESET"
log INFO "  VERBOSE:        $VERBOSE"

# Read confirmation for force reset
if [[ "$FORCE_RESET" == "true" ]]; then
    log WARN "FORCE RESET MODE: This will destroy all VMs and disks!"
    read -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
log HEADER "Step 1/8: Check Prerequisites"

run_step "1" "Checking prerequisites" "$STEPS_DIR/02-check-prerequisites.sh" \
    NETWORK_NAME="$NETWORK_NAME" \
    MASTER_NAME="$MASTER_NAME" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_NAME_PREFIX="$WORKER_NAME_PREFIX" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI"

# =============================================================================
# Step 2: Prepare Talos Image
# =============================================================================
log HEADER "Step 2/8: Prepare Talos Image"

if [[ "${USE_RAW_IMAGE:-false}" == "true" ]]; then
    run_step "2" "Preparing raw disk image" "$STEPS_DIR/03-prepare-raw-image.sh" \
        TALOS_RAW_IMAGE_URL="$TALOS_RAW_IMAGE_URL" \
        TALOS_RAW_IMAGE_PATH="$TALOS_RAW_IMAGE_PATH" \
        TALOS_RAW_IMAGE_COMPRESSED="$TALOS_RAW_IMAGE_COMPRESSED"
else
    run_step "2" "Preparing ISO image" "$STEPS_DIR/03-prepare-iso.sh" \
        TALOS_IMAGE_URL="$TALOS_IMAGE_URL" \
        TALOS_IMAGE_PATH="$TALOS_IMAGE_PATH"
fi

# =============================================================================
# Step 3: Create Storage Pool
# =============================================================================
log HEADER "Step 3/8: Create Storage Pool"

run_step "3" "Creating storage pool" "$STEPS_DIR/04-create-storage-pool.sh" \
    STORAGE_POOL="$STORAGE_POOL" \
    LIBVIRT_URI="$LIBVIRT_URI"

# Storage pool verification done in step script
log OK "Storage pool verification passed (from step script)"

# =============================================================================
# Step 4: Setup Network
# =============================================================================
log HEADER "Step 4/8: Setup Network"

run_step "4" "Setting up network" "$STEPS_DIR/05-setup-network.sh" \
    NETWORK_NAME="$NETWORK_NAME" \
    SCRIPT_DIR="$SCRIPT_DIR"

# Network verification done in step script, skip duplicate check
log OK "Network verification passed (from step script)"

# =============================================================================
# Step 5: Cleanup Existing VMs (if not skipped)
# =============================================================================
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    log HEADER "Step 5/8: Cleanup Existing VMs"

    # Export variables for the cleanup script subprocess
    export SKIP_CLEANUP NETWORK_NAME MASTER_NAME WORKER_COUNT WORKER_NAME_PREFIX STORAGE_POOL LIBVIRT_URI USE_RAW_IMAGE PROJECT_ROOT

    run_step "5" "Cleaning up existing VMs" "$STEPS_DIR/06-cleanup-vms.sh"
    STEP5_RAN=true
else
    log HEADER "Step 5/8: Skip Cleanup (requested)"
    log OK "Skipping VM cleanup"
    STEP5_RAN=false
fi

# Verify step 5 actually removed VMs from libvirt (it may fail silently)
log INFO "Verifying VMs are removed from libvirt..."
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${vm}" | awk '{print $2}' | head -1 || true)
    if [[ -n "$actual_vm" ]]; then
        log WARN "$actual_vm still exists after step 5 cleanup"
    fi
done

# =============================================================================
# Step 6: Start VMs with Vagrant
# =============================================================================
log HEADER "Step 6/8: Start VMs"

cd "$PROJECT_ROOT"

# Always remove any existing VMs from libvirt before vagrant up
# Step 5 may have cleaned via vagrant but VMs can still exist in libvirt
log INFO "Checking for existing VMs in libvirt..."
found_any=false
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    actual_vm=$(virsh -c "$LIBVIRT_URI" list --all 2>/dev/null | grep "${VM_PREFIX}${vm}" | awk '{print $2}' | head -1 || true)
    if [[ -n "$actual_vm" ]]; then
        found_any=true
        log INFO "Found: $actual_vm - removing..."

        # Stop the VM only if running
        vm_state=$(virsh -c "$LIBVIRT_URI" domstate "$actual_vm" 2>/dev/null)
        if [[ "$vm_state" == "running" ]]; then
            virsh -c "$LIBVIRT_URI" destroy "$actual_vm" >/dev/null 2>&1 || true
            sleep 1
        fi

        # Undefine with all storage
        if virsh -c "$LIBVIRT_URI" undefine "$actual_vm" --remove-all-storage >/dev/null 2>&1; then
            log OK "Removed VM and storage"
        else
            # Try to remove storage volumes manually
            disk_name="${actual_vm}-vda.raw"
            virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$disk_name" >/dev/null 2>&1 || true
            # Also try qcow2
            disk_name="${actual_vm}-vda.qcow2"
            virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$disk_name" >/dev/null 2>&1 || true
            # Also try direct file removal
            rm -f "$POOL_PATH/${actual_vm}-vda.raw" "$POOL_PATH/${actual_vm}-vda.qcow2" 2>/dev/null || true
            # Remove nvram
            sudo rm -f /var/lib/libvirt/qemu/nvram/${actual_vm}_VARS.fd 2>/dev/null || true
            # Undefine without storage removal
            virsh -c "$LIBVIRT_URI" undefine "$actual_vm" >/dev/null 2>&1 || true
            log OK "Removed VM (cleaned up manually)"
        fi
    fi
done

if [[ "$found_any" == "true" ]]; then
    log OK "All existing VMs removed from libvirt"
fi

log INFO "Starting VMs with Vagrant..."
if vagrant up --provider=libvirt 2>&1 | tee /tmp/vagrant-up.log; then
    # Check the actual exit status of vagrant up
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log ERROR "Vagrant failed to start VMs"
        echo ""
        echo "Check /tmp/vagrant-up.log for details"
        exit 1
    fi
    log OK "VMs started successfully"
else
    log ERROR "Vagrant failed to start VMs"
    echo ""
    echo "Check /tmp/vagrant-up.log for details"
    exit 1
fi

# Verify VMs are running
log INFO "Verifying VMs..."
for vm in "$MASTER_NAME" "${WORKER_NAME_PREFIX}1" "${WORKER_NAME_PREFIX}2"; do
    if virsh -c "$LIBVIRT_URI" domstate "${VM_PREFIX}$vm" 2>/dev/null | grep -q "running"; then
        log OK "VM $vm is running"
    else
        log ERROR "VM $vm is not running"
        exit 1
    fi
done

# =============================================================================
# Step 7: Configure UEFI (skipped - Talos works fine with BIOS boot)
# =============================================================================
log HEADER "Step 7/8: Skip UEFI Configuration"

log OK "UEFI configuration skipped (Talos works with BIOS boot)"

# =============================================================================
# Step 8: Wait for Talos to Boot
# =============================================================================
log HEADER "Step 8/8: Wait for Talos Boot"

run_step "8" "Waiting for Talos boot" "$STEPS_DIR/08-wait-for-talos.sh" \
    MASTER_IP="$MASTER_IP" \
    WORKER_COUNT="$WORKER_COUNT" \
    WORKER_IP_BASE="$WORKER_IP_BASE" \
    LIBVIRT_URI="$LIBVIRT_URI"

# =============================================================================
# Summary
# =============================================================================
log HEADER "Startup Complete"

log OK "All VMs started successfully!"
log INFO ""
log INFO "Next steps:"
log INFO "  1. Bootstrap Talos cluster:"
log INFO "     ./scripts/talos-bootstrap.sh"
log INFO ""
log INFO "  2. Monitor VM status:"
log INFO "     virsh -c $LIBVIRT_URI list"
log INFO ""
log INFO "  3. Access VM console (if needed):"
log INFO "     virsh -c $LIBVIRT_URI console ${VM_PREFIX}$MASTER_NAME"

exit 0
