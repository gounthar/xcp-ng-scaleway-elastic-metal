#!/bin/bash
set -euo pipefail

# Install XCP-ng on Scaleway Elastic Metal via QEMU disk passthrough
#
# Designed to run in Scaleway rescue mode where disks are unmounted.
# Uses QEMU with KVM to boot the XCP-ng installer with a real disk
# passed through as virtio, then applies post-install fixes for
# bare-metal boot compatibility.
#
# Prerequisites:
#   - Scaleway Elastic Metal in rescue mode (disks unmounted)
#   - SSH access as rescue@<server-ip>
#   - build-iso.sh and answerfile.xml in the same directory
#
# What this does:
#   1. Installs QEMU and build dependencies
#   2. Detects hardware (UEFI/BIOS, disk layout, NIC model)
#   3. Thoroughly wipes target disk
#   4. Builds custom XCP-ng ISO with answerfile
#   5. Launches QEMU with disk passthrough + correct boot mode
#   6. Waits for installer to complete (-no-reboot)
#   7. Rebuilds initramfs with real hardware drivers
#   8. Validates installed system boots inside QEMU
#   9. Configures real networking via xe CLI
#   10. Converts GPT to MBR on Dell hardware (DellPartition.efi workaround)
#   11. Fixes XAPI first-boot config (management.conf, default-storage.conf)
#   12. Reports ready for bare-metal reboot
#
# Key fixes applied post-install:
#   - Fix 1: UEFI/BIOS must match between QEMU and real hardware
#   - Fix 2: initramfs needs real SATA/NIC drivers (not just virtio)
#   - Fix 3: OVS networking (TYPE=OVSBridge/OVSPort), NOT Linux bridges
#   - Fix 4: Thorough disk wipe (mdadm + wipefs + sgdisk + dd)
#   - Fix 5: Pre-reboot validation inside QEMU
#   - Fix 6: GPT→MBR on Dell (DellPartition.efi crashes on GPT in Legacy BIOS)
#   - Fix 7: XAPI management.conf/default-storage.conf (QEMU leaves wrong values)
#
# Lessons learned (2026-02-28 through 2026-03-01):
#   - NEVER pass a disk to QEMU if the host OS runs from it (RAID corruption!)
#   - QEMU virtio disks appear as /dev/vda inside VM
#   - -no-reboot makes QEMU exit when installer reboots (completion signal)
#   - 24GB for QEMU + 8GB for host is tight — monitor SSH stability
#   - QEMU SLIRP gives installer internet access (10.0.2.15, DNS 10.0.2.3)
#   - Xen dom0 CANNOT see QEMU's CD-ROM → must serve packages via HTTP
#   - network_device=eth0 boot param is REQUIRED when answerfile=file://
#     (otherwise init_network stays False and dom0 networking is never configured)
#   - XCP-ng uses ext3 (not ext4!) for root and log partitions
#   - Scaleway reboot boot-type=X FAILS on custom-installed servers (PXE loop!)
#     Must use stop+start instead: scw baremetal server stop; scw baremetal server start boot-type=normal
#   - grub-mkconfig needs /etc/default/grub to generate Xen multiboot entries
#   - GRUB must be re-installed to MBR after install (grub-install /dev/sdX)
#   - dracut 033 (XCP-ng 8.3) does NOT have --force-drivers flag!
#     Use /etc/dracut.conf.d/ config file with add_drivers+= instead.
#     Config file approach works unconditionally, even in chroot where
#     dracut can't detect real hardware via /sys.
#   - dracut MUST specify kernel version explicitly (positional arg or --kver)
#     to avoid building initramfs for the rescue system's kernel
#   - Always verify initramfs contents with lsinitrd before rebooting to bare metal
#   - Dell BIOS DellPartition.efi crashes on GPT partition tables (General Protection Fault 13)
#     Convert GPT→MBR with sgdisk --gpttombr before GRUB install on Dell hardware
#   - XCP-ng uses Open vSwitch, NOT Linux bridges! ifcfg files MUST use TYPE=OVSBridge/OVSPort
#     with DEVICETYPE=ovs. TYPE=Bridge causes silent network failure (xsconsole shows, no connectivity)
#   - XAPI management.conf stores first-boot NIC/IP config. QEMU leaves eth0/dhcp/10.0.2.3
#     Must fix BEFORE first boot to real NIC/static/real-IP or networking won't work
#   - iDRAC accessible via Scaleway BMC API: scw baremetal bmc get + RACADM SSH
#   - OS-level `reboot` command does NOT work on Scaleway Elastic Metal!
#     The BMC does not power-cycle automatically. Server stays off after shutdown.
#     Must use Scaleway API: scw baremetal server stop; scw baremetal server start boot-type=normal
#   - grub-mkconfig puts Linux fallback entries BEFORE Xen entries. Default entry 0
#     boots plain Linux without Xen hypervisor. XAPI runs but VMs fail with "HVM not supported".
#     Must set GRUB default to first Xen entry after generating grub.cfg.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# Load XCP-ng version from shared env file (single source of truth)
if [ -z "${XCP_NG_VERSION:-}" ]; then
    # shellcheck source=xcp-ng-version.env
    source "${SCRIPT_DIR}/xcp-ng-version.env" \
        || { echo "ERROR: xcp-ng-version.env not found and XCP_NG_VERSION not set"; exit 1; }
fi
if [ -z "${XCP_NG_VERSION:-}" ]; then
    echo "ERROR: XCP_NG_VERSION is empty after sourcing xcp-ng-version.env"
    exit 1
fi
export XCP_NG_VERSION
XCP_NG_MAJOR="${XCP_NG_VERSION%.*}"   # e.g. 8.3.0-20250606 → 8.3
LOG_FILE="/tmp/xcp-ng-install.log"
SERIAL_LOG="/tmp/qemu-xcpng-serial.log"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR}"

# Target disk — in rescue mode both disks are available
TARGET_DISK="${TARGET_DISK:-/dev/sda}"

# Ensure we run as root (rescue mode user needs sudo)
if [ "$(id -u)" -ne 0 ]; then
    echo "Re-running as root via sudo..."
    exec sudo -E bash "$0" "$@"
fi

# Server's real network config (set these before running!)
REAL_IP="${REAL_IP:-}"
REAL_GATEWAY="${REAL_GATEWAY:-}"
REAL_NETMASK="${REAL_NETMASK:-255.255.255.0}"
REAL_DNS="${REAL_DNS:-51.159.47.28}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
die() { log "FATAL: $*"; exit 1; }

# --- Timing instrumentation ---
declare -A _PHASE_START
_SCRIPT_START=$(date +%s)
TIMING_LOG=$(mktemp /tmp/xcp-ng-install-timing.XXXXXX)
: > "$TIMING_LOG"

phase_start() {
    local name="$1"
    _PHASE_START[$name]=$(date +%s)
    log ">>> START: $name"
}

phase_end() {
    local name="$1"
    if [[ -z "${_PHASE_START[$name]:-}" ]]; then
        log "WARN: phase_end called for unstarted phase: $name"
        return
    fi
    local start=${_PHASE_START[$name]}
    local elapsed=$(( $(date +%s) - start ))
    local min=$((elapsed / 60))
    local sec=$((elapsed % 60))
    log "<<< END: $name (${min}m ${sec}s)"
    echo "$name|$elapsed" >> "$TIMING_LOG"
}

print_timing_summary() {
    local total=$(( $(date +%s) - _SCRIPT_START ))
    local total_min=$((total / 60))
    local total_sec=$((total % 60))
    log ""
    log "=== TIMING SUMMARY ==="
    if [ -f "$TIMING_LOG" ]; then
        while IFS='|' read -r name elapsed; do
            local m=$((elapsed / 60))
            local s=$((elapsed % 60))
            printf "  %-40s %3dm %02ds\n" "$name" "$m" "$s" | tee -a "$LOG_FILE"
        done < "$TIMING_LOG"
    fi
    printf "  %-40s %3dm %02ds\n" "TOTAL" "$total_min" "$total_sec" | tee -a "$LOG_FILE"
    log "======================"
}

# =============================================================================
# Step 0: Validate environment
# =============================================================================
log "=== Step 0: Validate environment ==="

if [ -z "$REAL_IP" ] || [ -z "$REAL_GATEWAY" ]; then
    die "REAL_IP and REAL_GATEWAY must be set. Example:
  export REAL_IP=203.0.113.10
  export REAL_GATEWAY=203.0.113.1
  bash install-via-qemu.sh"
fi

if [ ! -b "$TARGET_DISK" ]; then
    echo "Available disks:"
    lsblk
    die "Target disk $TARGET_DISK not found"
fi

# Check we're in rescue mode (not running from target disk)
if mount | grep -q "$TARGET_DISK"; then
    die "$TARGET_DISK is mounted! Are you sure you're in rescue mode?"
fi

log "Target disk: $TARGET_DISK"
log "Real IP: $REAL_IP"
log "Real gateway: $REAL_GATEWAY"

# =============================================================================
# Step 1: Install dependencies
# =============================================================================
phase_start "Dependencies install"
log "=== Step 1: Install dependencies ==="
# Rescue mode is Ubuntu 20.04 (Focal) — some package names differ from newer releases
apt-get update -qq
apt-get install -y -qq \
    qemu-system-x86 qemu-utils ovmf \
    curl genisoimage syslinux-utils libarchive-tools bzip2 cpio \
    mdadm gdisk pciutils lvm2 sshpass
# Verify critical tools are available
for tool in qemu-system-x86_64 genisoimage bsdtar sgdisk; do
    if ! command -v "$tool" &>/dev/null; then
        die "Required tool '$tool' not found after install"
    fi
done
log "Dependencies installed and verified"
phase_end "Dependencies install"

# =============================================================================
# Step 2: Detect hardware
# =============================================================================
phase_start "Hardware detection"
log "=== Step 2: Detect hardware ==="

# Hardware lottery — what did we get?
log "--- Hardware Discovery ---"
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
BIOS_VENDOR=$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "unknown")
log "System: $VENDOR $PRODUCT"
log "BIOS vendor: $BIOS_VENDOR"

# Detect UEFI vs BIOS
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="uefi"
    log "Boot mode: UEFI (EFI vars present)"
else
    BOOT_MODE="bios"
    log "Boot mode: Legacy BIOS"
fi

# Detect NIC model (for initramfs driver list)
log "--- NIC Discovery ---"
NIC_DRIVERS=""
for nic in /sys/class/net/*/device/driver; do
    if [ -e "$nic" ]; then
        drv=$(basename "$(readlink -f "$nic")")
        iface=$(echo "$nic" | cut -d/ -f5)
        log "NIC: $iface -> driver: $drv"
        NIC_DRIVERS="$NIC_DRIVERS $drv"
    fi
done
NIC_DRIVERS=$(echo "$NIC_DRIVERS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
log "Unique NIC drivers: $NIC_DRIVERS"

# Detect storage controller (for initramfs driver list)
log "--- Storage Discovery ---"
STORAGE_DRIVERS=""
for disk in /sys/block/sd*/device/../driver; do
    if [ -e "$disk" ]; then
        drv=$(basename "$(readlink -f "$disk")")
        STORAGE_DRIVERS="$STORAGE_DRIVERS $drv"
    fi
done
STORAGE_DRIVERS=$(echo "$STORAGE_DRIVERS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
log "Unique storage drivers: $STORAGE_DRIVERS"
phase_end "Hardware detection"

# Disk layout
log "--- Disk Layout ---"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL | tee -a "$LOG_FILE"

# =============================================================================
# Step 3: Thoroughly wipe target disk (Brainstorm Fix 4)
# =============================================================================
phase_start "Disk wipe"
log "=== Step 3: Wipe target disk ($TARGET_DISK) ==="

# Remove any mdadm superblocks
for part in ${TARGET_DISK}*; do
    if [ -b "$part" ] && [ "$part" != "$TARGET_DISK" ]; then
        mdadm --zero-superblock "$part" 2>/dev/null || true
        log "Cleared mdadm superblock: $part"
    fi
done

# Wipe all filesystem signatures
wipefs -a "$TARGET_DISK" 2>/dev/null || true
log "Wiped filesystem signatures"

# Destroy partition table (GPT + MBR)
sgdisk --zap-all "$TARGET_DISK" 2>/dev/null || true
log "Destroyed partition table"

# Zero first and last 10MB (catches any remaining metadata)
DISK_SIZE_MB=$(blockdev --getsize64 "$TARGET_DISK" | awk '{printf "%d", $1/1024/1024}')
dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$TARGET_DISK" bs=1M seek=$((DISK_SIZE_MB - 10)) count=10 conv=notrunc 2>/dev/null
log "Zeroed first and last 10MB"

# Verify disk is clean
log "Disk state after wipe:"
lsblk "$TARGET_DISK" -o NAME,SIZE,TYPE,FSTYPE 2>/dev/null | tee -a "$LOG_FILE"
phase_end "Disk wipe"

# =============================================================================
# Step 4: Build custom ISO
# =============================================================================
phase_start "ISO build"
log "=== Step 4: Build custom ISO ==="

mkdir -p "$WORK_DIR"

# Copy build files (skip if SCRIPT_DIR and WORK_DIR are the same)
if [ "$(realpath "$SCRIPT_DIR")" != "$(realpath "$WORK_DIR")" ]; then
    if [ -f "$SCRIPT_DIR/build-iso.sh" ]; then
        cp "$SCRIPT_DIR/build-iso.sh" "$WORK_DIR/"
        cp "$SCRIPT_DIR/answerfile.xml" "$WORK_DIR/"
    else
        die "build-iso.sh not found in $SCRIPT_DIR"
    fi
else
    # Files already in place — just verify
    [ -f "$WORK_DIR/build-iso.sh" ] || die "build-iso.sh not found in $WORK_DIR"
    [ -f "$WORK_DIR/answerfile.xml" ] || die "answerfile.xml not found in $WORK_DIR"
fi

export WORK="$WORK_DIR"
bash "$WORK_DIR/build-iso.sh" 2>&1 | tee -a "$LOG_FILE"

ISO_FILE="$WORK_DIR/xcp-ng-${XCP_NG_MAJOR}-unattended.iso"
if [ ! -f "$ISO_FILE" ]; then
    die "ISO build failed — $ISO_FILE not found"
fi
log "ISO built: $(ls -lh "$ISO_FILE" | awk '{print $5}')"
phase_end "ISO build"

# =============================================================================
# Step 5: Launch QEMU (Brainstorm Fix 1: match boot mode)
# =============================================================================
phase_start "HTTP repo setup"
log "=== Step 4b: Start HTTP server for package repository ==="
# The XCP-ng installer inside QEMU can't see the CD-ROM from Xen dom0.
# Solution: serve the full ISO contents via HTTP. QEMU SLIRP maps 10.0.2.2
# to the host, so the installer fetches packages from http://10.0.2.2:8099/
REPO_DIR="$WORK_DIR/full-iso-repo"
HTTP_PORT=8099

if [ ! -d "$REPO_DIR" ] || [ ! -f "$REPO_DIR/.treeinfo" ]; then
    die "Full ISO repository not found at $REPO_DIR. Run build-iso.sh first."
fi

# Kill any existing HTTP server on our port
fuser -k ${HTTP_PORT}/tcp 2>/dev/null || true
sleep 1

# Start HTTP server in background
cd "$REPO_DIR"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 &>/tmp/http-repo-server.log &
HTTP_PID=$!
cd "$WORK_DIR"

# Verify it's running
sleep 2
if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    die "HTTP server failed to start. Check /tmp/http-repo-server.log"
fi
log "HTTP repo server running on port $HTTP_PORT (PID: $HTTP_PID)"
log "  Serving: $REPO_DIR"
log "  Inside QEMU: http://10.0.2.2:$HTTP_PORT/"

# Quick self-test
if curl -sf "http://127.0.0.1:$HTTP_PORT/.treeinfo" | head -1 | grep -q '\[platform\]'; then
    log "  Self-test: .treeinfo accessible OK"
else
    kill "$HTTP_PID" 2>/dev/null || true
    die "HTTP server self-test failed — .treeinfo not accessible"
fi
phase_end "HTTP repo setup"

phase_start "QEMU install"
log "=== Step 5: Launch QEMU installer ==="

# shellcheck disable=SC2054  # Commas are QEMU argument syntax, not array separators
QEMU_ARGS=(
    -enable-kvm
    -m 24576                                    # 24GB RAM (leave 8GB for host)
    -smp 4
    -cpu host                                    # Pass through real CPU features
    -drive "file=$TARGET_DISK,format=raw,if=virtio,cache=none"  # Real disk as virtio
    -cdrom "$ISO_FILE"                          # Netinstall ISO for boot only
    -boot d                                      # Boot from CD-ROM
    -netdev user,id=net0                         # SLIRP networking (NAT + DHCP)
    -device virtio-net-pci,netdev=net0
    -vnc 127.0.0.1:0                             # VNC on port 5900 (use SSH tunnel)
    -serial "file:$SERIAL_LOG"                   # Serial console to log
    -no-reboot                                   # Exit when installer reboots
    -display none
)

# Brainstorm Fix 1: Match boot mode
if [ "$BOOT_MODE" = "uefi" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        QEMU_ARGS+=(-bios /usr/share/OVMF/OVMF_CODE.fd)
        log "UEFI mode: using OVMF"
    else
        log "WARNING: UEFI detected but OVMF not found — falling back to SeaBIOS"
        log "Install with: apt-get install ovmf"
    fi
else
    log "BIOS mode: using SeaBIOS (default)"
fi

log "Starting QEMU with ${#QEMU_ARGS[@]} arguments..."
log "VNC bound to 127.0.0.1:5900 — use SSH tunnel: ssh -L 5900:127.0.0.1:5900 user@host"
log "Serial log: $SERIAL_LOG"

# Launch in background
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!
log "QEMU PID: $QEMU_PID"

# =============================================================================
# Step 6: Wait for installation to complete
# =============================================================================
log "=== Step 6: Waiting for installer to complete ==="
log "(-no-reboot flag: QEMU exits when installer reboots)"
log "Monitor: tail -f $SERIAL_LOG"

TIMEOUT=1800  # 30 minutes max
ELAPSED=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    # Check disk I/O as activity indicator
    DISK_IO=$(awk -v d="$(basename "$TARGET_DISK")" '
        $3 == d { print $6 + $10; found=1; exit }
        END { if (!found) print 0 }
    ' /proc/diskstats)
    log "  Elapsed: ${ELAPSED}s | Disk I/O sectors: ${DISK_IO:-0} | QEMU running"
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        log "TIMEOUT: Installation did not complete within ${TIMEOUT}s"
        kill "$QEMU_PID" 2>/dev/null || true
        die "Installation timed out. Check VNC and serial log."
    fi
done

QEMU_EXIT=0
wait "$QEMU_PID" || QEMU_EXIT=$?
if [ "$QEMU_EXIT" -ne 0 ]; then
    log "WARNING: QEMU exited with status $QEMU_EXIT — check serial log: $SERIAL_LOG"
    tail -30 "$SERIAL_LOG" 2>/dev/null | tee -a "$LOG_FILE" || true
    die "QEMU exited with non-zero status ($QEMU_EXIT). Installation may have failed."
fi
log "QEMU exited successfully — installer completed"

# Stop the HTTP server
if [ -n "${HTTP_PID:-}" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
    kill "$HTTP_PID" 2>/dev/null || true
    log "HTTP repo server stopped"
fi

log "Last 20 lines of serial log:"
tail -20 "$SERIAL_LOG" 2>/dev/null | tee -a "$LOG_FILE" || true

# Quick sanity check — does the disk have partitions now?
if ! lsblk "$TARGET_DISK" | grep -q "part"; then
    die "No partitions found on $TARGET_DISK after install. Installation likely failed."
fi
log "Partitions found on $TARGET_DISK:"
lsblk "$TARGET_DISK" -o NAME,SIZE,TYPE,FSTYPE | tee -a "$LOG_FILE"
phase_end "QEMU install"

# =============================================================================
# Step 7: Rebuild initramfs with real drivers (Brainstorm Fix 2)
# =============================================================================
phase_start "Post-install chroot fixes"
log "=== Step 7: Rebuild initramfs with real hardware drivers ==="

# Find the XCP-ng root and boot partitions
# XCP-ng typically: partition 1 = boot (ext4), partition 2 = root (ext4), partition 3+ = LVM
ROOT_PART=""
BOOT_PART=""
for part in ${TARGET_DISK}1 ${TARGET_DISK}2 ${TARGET_DISK}3; do
    if [ -b "$part" ]; then
        FSTYPE=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        LABEL=$(blkid -o value -s LABEL "$part" 2>/dev/null || true)
        log "  $part: fstype=$FSTYPE label=$LABEL"
        # XCP-ng uses ext3 (not ext4!) for root and log partitions
        if echo "$FSTYPE" | grep -qE '^ext[234]$' && [ -z "$ROOT_PART" ]; then
            # Try mounting to check if it's root
            mount "$part" /mnt 2>/dev/null || continue
            if [ -f /mnt/etc/xensource-inventory ]; then
                ROOT_PART="$part"
                log "  Found root: $ROOT_PART"
            elif [ -d /mnt/grub ] || [ -d /mnt/efi ]; then
                BOOT_PART="$part"
                log "  Found boot: $BOOT_PART"
                umount /mnt
            else
                umount /mnt
            fi
        fi
    fi
done

if [ -z "$ROOT_PART" ]; then
    # Root might be on LVM
    log "Root not found on simple partitions, checking LVM..."
    vgscan 2>/dev/null || true
    vgchange -ay 2>/dev/null || true
    for lv in /dev/mapper/*-root /dev/*/root; do
        if [ -b "$lv" ]; then
            mount "$lv" /mnt 2>/dev/null || continue
            if [ -f /mnt/etc/xensource-inventory ]; then
                ROOT_PART="$lv"
                log "  Found root on LVM: $ROOT_PART"
                break
            fi
            umount /mnt
        fi
    done
fi

if [ -z "$ROOT_PART" ]; then
    log "WARNING: Could not find XCP-ng root partition automatically"
    log "Manual inspection needed. Current partition layout:"
    lsblk "$TARGET_DISK" -o NAME,SIZE,TYPE,FSTYPE,LABEL | tee -a "$LOG_FILE"
    log "Skipping initramfs rebuild — you'll need to do this manually"
else
    # Root is mounted at /mnt
    if [ -n "$BOOT_PART" ]; then
        mount "$BOOT_PART" /mnt/boot 2>/dev/null || true
    fi
    mountpoint -q /mnt/dev  || mount --bind /dev /mnt/dev
    mountpoint -q /mnt/proc || mount --bind /proc /mnt/proc
    mountpoint -q /mnt/sys  || mount --bind /sys /mnt/sys

    # Build the driver list from detected hardware
    # Always include common SATA + known Scaleway NIC drivers (tg3 for Broadcom, e1000e/igb for Intel)
    ALL_DRIVERS="ahci sd_mod ata_piix ata_generic tg3 bnx2 e1000e igb $STORAGE_DRIVERS $NIC_DRIVERS"
    ALL_DRIVERS=$(echo "$ALL_DRIVERS" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    log "Injecting drivers: $ALL_DRIVERS"

    # Find the installed kernel version
    KVER=$(ls /mnt/lib/modules/ | head -1)
    if [ -n "$KVER" ]; then
        log "Kernel version: $KVER"
        # CRITICAL: dracut 033 (XCP-ng 8.3) does NOT have --force-drivers!
        # The --add-drivers flag silently skips modules it deems "unneeded" in chroot
        # because it can't detect real hardware via /sys. The reliable fix is a
        # config file in /etc/dracut.conf.d/ — add_drivers+= is always honored.
        # The kernel version MUST be passed explicitly (positional arg) to avoid
        # dracut targeting the rescue system's kernel instead of XCP-ng's.
        cat > /mnt/etc/dracut.conf.d/bare-metal-drivers.conf << DRACUTEOF
# Force inclusion of bare metal drivers (QEMU install only has virtio)
# Config file approach required: dracut 033 lacks --force-drivers flag
add_drivers+=" ${ALL_DRIVERS} ext3 ext4 "
DRACUTEOF
        log "Created /etc/dracut.conf.d/bare-metal-drivers.conf"
        chroot /mnt dracut --force \
            /boot/initramfs-${KVER}.img "$KVER" 2>&1 | tee -a "$LOG_FILE"
        log "initramfs rebuilt with real hardware drivers"

        # Verify critical drivers are actually present
        log "Verifying initramfs contents..."
        INITRD_CHECK=$(chroot /mnt lsinitrd /boot/initramfs-${KVER}.img 2>/dev/null | grep -cE 'ahci|sd_mod|tg3' || true)
        if [ "${INITRD_CHECK:-0}" -ge 2 ]; then
            log "VERIFIED: Found $INITRD_CHECK storage/NIC driver entries in initramfs"
        else
            log "WARNING: Only found $INITRD_CHECK driver entries — initramfs may be incomplete!"
            log "Manual check: chroot /mnt lsinitrd /boot/initramfs-${KVER}.img | grep -E 'ahci|sd_mod|tg3'"
        fi
    else
        log "WARNING: No kernel modules found in /mnt/lib/modules/"
    fi

    # -------------------------------------------------------------------------
    # Step 7b: Fix vda→sda references from QEMU virtio
    # -------------------------------------------------------------------------
    log "--- Step 7b: Fix disk references (vda → real disk) ---"
    REAL_DISK_NAME=$(basename "$TARGET_DISK")
    if grep -q 'vda' /mnt/etc/xensource-inventory 2>/dev/null; then
        sed -i "s|/dev/vda|/dev/${REAL_DISK_NAME}|g" /mnt/etc/xensource-inventory
        log "Fixed xensource-inventory: vda → ${REAL_DISK_NAME}"
    fi

    # -------------------------------------------------------------------------
    # Step 7c: GPT→MBR conversion (Dell firmware workaround)
    # -------------------------------------------------------------------------
    # Dell BIOS 1.11.0 has DellPartition.efi that crashes with General Protection
    # Fault (exception 13) when scanning GPT partition tables, even in Legacy BIOS mode.
    # Symptom: black screen with blinking underscore — GRUB never loads.
    # Fix: convert GPT to MBR. Safe because disk < 2TB and fstab uses LABEL=.
    if echo "$VENDOR" | grep -qi "dell"; then
        log "--- Step 7c: GPT→MBR conversion (Dell firmware workaround) ---"
        if gdisk -l "$TARGET_DISK" 2>/dev/null | grep -q "GPT:.*present"; then
            log "Dell hardware detected with GPT — converting to MBR to avoid DellPartition.efi crash"

            # Discover XCP-ng partition layout (typically: root, backup, SR, BIOS-boot, logs, swap)
            # We need to map the important ones into MBR's 4-partition limit
            # Standard XCP-ng GPT: 1=root, 2=backup, 3=SR(LVM), 4=BIOS-boot, 5=logs, 6=swap
            # MBR mapping: logs→1, root→2(bootable), swap→3, SR→4
            sgdisk --gpttombr=5:1:6:3 "$TARGET_DISK" 2>&1 | tee -a "$LOG_FILE"

            # Fix partition types (sgdisk --gpttombr may set wrong types)
            echo -e "t\n1\n83\nt\n2\n83\nt\n3\n82\nt\n4\n8e\nw" | fdisk "$TARGET_DISK" 2>&1 | tee -a "$LOG_FILE" || true
            # Set bootable flag on root (partition 2)
            echo -e "a\n2\nw" | fdisk "$TARGET_DISK" 2>&1 | tee -a "$LOG_FILE" || true

            log "GPT→MBR conversion complete"
            log "Partition layout:"
            fdisk -l "$TARGET_DISK" 2>/dev/null | tee -a "$LOG_FILE"

            # Re-mount root (partition numbering may have changed)
            umount /mnt/sys 2>/dev/null || true
            umount /mnt/proc 2>/dev/null || true
            umount /mnt/dev 2>/dev/null || true
            umount /mnt/boot 2>/dev/null || true
            umount /mnt 2>/dev/null || true

            # After GPT→MBR, partition numbers change. Find root again by label.
            for part in ${TARGET_DISK}1 ${TARGET_DISK}2 ${TARGET_DISK}3 ${TARGET_DISK}4; do
                LABEL=$(blkid -o value -s LABEL "$part" 2>/dev/null || true)
                if echo "$LABEL" | grep -q "^root-"; then
                    mount "$part" /mnt
                    log "Re-mounted root: $part (LABEL=$LABEL)"
                    break
                fi
            done
            if ! mountpoint -q /mnt || [ ! -f /mnt/etc/xensource-inventory ]; then
                die "Failed to remount XCP-ng root after GPT→MBR conversion"
            fi
            mountpoint -q /mnt/dev  || mount --bind /dev /mnt/dev
            mountpoint -q /mnt/proc || mount --bind /proc /mnt/proc
            mountpoint -q /mnt/sys  || mount --bind /sys /mnt/sys

            # Remove any ESP fstab entry (no longer relevant with MBR)
            sed -i '/\/boot\/efi/d' /mnt/etc/fstab 2>/dev/null || true
        else
            log "Dell hardware but no GPT detected — skipping MBR conversion"
        fi
    fi

    # -------------------------------------------------------------------------
    # Step 7d: Fix GRUB configuration for Xen multiboot
    # -------------------------------------------------------------------------
    log "--- Step 7d: Fix GRUB for Xen multiboot ---"

    # XCP-ng's grub-mkconfig needs /etc/default/grub to generate Xen entries.
    # Without it, only plain Linux entries are generated (no multiboot2 /boot/xen.gz).
    if [ ! -f /mnt/etc/default/grub ]; then
        cat > /mnt/etc/default/grub << 'GRUBEOF'
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="XCP-ng"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
GRUB_CMDLINE_LINUX=""
GRUB_CMDLINE_XEN_DEFAULT="dom0_max_vcpus=1-16 dom0_mem=max:8192M com1=115200,8n1 console=com1,vga"
GRUBEOF
        log "Created /etc/default/grub"
    fi

    # Remount bind filesystems for chroot (idempotent — skip if already mounted)
    mountpoint -q /mnt/dev  || mount --bind /dev /mnt/dev
    mountpoint -q /mnt/proc || mount --bind /proc /mnt/proc
    mountpoint -q /mnt/sys  || mount --bind /sys /mnt/sys

    # Install GRUB to MBR and generate config
    chroot /mnt grub-install "$TARGET_DISK" 2>&1 | tee -a "$LOG_FILE"
    chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$LOG_FILE"

    # Verify Xen multiboot entries exist
    if grep -q 'multiboot2.*xen' /mnt/boot/grub/grub.cfg 2>/dev/null; then
        log "GRUB: Xen multiboot entries generated OK"

        # CRITICAL: grub-mkconfig puts Linux fallback entries BEFORE Xen entries.
        # Without setting the default, GRUB boots entry 0 (Linux fallback) — which
        # boots a plain Linux kernel WITHOUT Xen. XAPI runs but cannot start VMs
        # because there's no hypervisor loaded. Must set default to first Xen entry.
        XEN_ENTRY=$(grep -n "^menuentry.*with Xen xen" /mnt/boot/grub/grub.cfg 2>/dev/null | head -1)
        if [ -n "$XEN_ENTRY" ]; then
            # Count menuentry lines before the Xen entry to get its index
            XEN_LINE=$(echo "$XEN_ENTRY" | cut -d: -f1)
            XEN_IDX=0
            while IFS= read -r line; do
                LINE_NUM=$(echo "$line" | cut -d: -f1)
                if [ "$LINE_NUM" -ge "$XEN_LINE" ]; then
                    break
                fi
                XEN_IDX=$((XEN_IDX + 1))
            done < <(grep -n "^menuentry" /mnt/boot/grub/grub.cfg)
            # XCP-ng 8.3 uses grub-set-default (no "2" prefix), at /usr/sbin/
            if chroot /mnt /usr/sbin/grub-set-default "$XEN_IDX" 2>/dev/null || \
               chroot /mnt grub2-set-default "$XEN_IDX" 2>/dev/null || \
               chroot /mnt grub-set-default "$XEN_IDX" 2>/dev/null; then
                log "GRUB: Default set to Xen entry (index $XEN_IDX)"
            else
                die "Failed to set GRUB default to Xen entry index $XEN_IDX"
            fi
        fi
    else
        log "WARNING: No Xen multiboot entries in grub.cfg — boot may fail!"
    fi

    # -------------------------------------------------------------------------
    # Step 7c: Configure bare-metal networking
    # -------------------------------------------------------------------------
    log "--- Step 7e: Configure bare-metal networking ---"

    # Detect the real NIC MAC address from rescue mode.
    # IMPORTANT: XCP-ng's interface-rename service remaps NIC names on first boot.
    # The rescue-mode name (eno1, enp1s0) will NOT be the name inside XCP-ng.
    # The installer used eth0 inside QEMU (virtio NIC). On bare-metal first boot,
    # interface-rename sees the old QEMU MAC as "eth0" and assigns the real NIC
    # to eth1/eth2 (since eth0 is "taken" by the stale QEMU entry).
    #
    # Fix: pre-populate dynamic-rules.json to map the real MAC to eth0,
    # replacing the stale QEMU entry. This way the real NIC becomes eth0 on boot.
    REAL_NIC_MAC=""
    REAL_NIC_RESCUE=""
    for nic in /sys/class/net/*/device; do
        iface=$(echo "$nic" | cut -d/ -f5)
        if [ "$iface" != "lo" ]; then
            REAL_NIC_RESCUE="$iface"
            REAL_NIC_MAC=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
            break
        fi
    done
    REAL_NIC_RESCUE="${REAL_NIC_RESCUE:-eno1}"
    # The NIC name inside XCP-ng will be eth0 (we force it via dynamic-rules.json)
    XCPNG_NIC="eth0"
    log "Rescue NIC: $REAL_NIC_RESCUE (MAC: $REAL_NIC_MAC) → XCP-ng NIC: $XCPNG_NIC"

    # Fix interface-rename so the real NIC gets eth0 on bare-metal boot.
    #
    # Problem: The QEMU installer creates dynamic-rules.json with the virtio
    # NIC (MAC 52:54:00:12:34:56) as eth0. On bare-metal first boot, interface-rename
    # sees the QEMU MAC is gone, moves it to "old", and assigns the real NICs
    # starting from eth1/eth2 (since eth0 is "taken" by the stale entry).
    #
    # Previous approach (dynamic-rules.json overwrite) DOES NOT WORK because
    # interface-rename regenerates dynamic-rules.json on first boot, overwriting
    # our changes.
    #
    # Correct fix: Use static-rules.conf which OVERRIDES dynamic assignment.
    # A mac rule here forces the real MAC to eth0 regardless of what
    # interface-rename discovers dynamically.
    RENAME_DIR="/mnt/etc/sysconfig/network-scripts/interface-rename-data"
    if [ -d "$RENAME_DIR" ] && [ -n "$REAL_NIC_MAC" ]; then
        # Write static rule: real MAC → eth0 (overrides dynamic assignment)
        cat > "$RENAME_DIR/static-rules.conf" << RENAMEEOF
# Static rules.  Written by install-via-qemu.sh for bare-metal boot.
# Maps the real NIC MAC to eth0, overriding the stale QEMU virtio entry
# that would otherwise push real NICs to eth1/eth2.

eth0: mac = "$REAL_NIC_MAC"
RENAMEEOF
        log "Wrote static-rules.conf: $REAL_NIC_MAC → eth0"

        # Also clean up dynamic-rules.json to remove the stale QEMU entry
        NIC_PCI=$(readlink -f "/sys/class/net/$REAL_NIC_RESCUE/device" 2>/dev/null | sed 's|.*/||')
        NIC_PCI="${NIC_PCI:-0000:01:00.0}"
        cat > "$RENAME_DIR/dynamic-rules.json" << RENAMEEOF
{
    "lastboot": [
        [
            "$REAL_NIC_MAC",
            "${NIC_PCI}[0]",
            "eth0"
        ]
    ],
    "old": []
}
RENAMEEOF
        log "Also cleaned dynamic-rules.json: removed stale QEMU entry"
    fi

    # Remove stale ifcfg-eno1 or other rescue-mode NIC configs
    rm -f /mnt/etc/sysconfig/network-scripts/ifcfg-eno* 2>/dev/null
    rm -f /mnt/etc/sysconfig/network-scripts/ifcfg-enp* 2>/dev/null

    # XCP-ng uses Open vSwitch (OVS), NOT Linux bridges!
    # network.conf says "openvswitch" — ifcfg files MUST use OVS types.
    # Using TYPE=Bridge instead of TYPE=OVSBridge causes silent networking failure:
    # XCP-ng boots fine (xsconsole shows) but has zero network connectivity.
    #
    # ifcfg-xenbr0: OVS bridge with the IP
    cat > /mnt/etc/sysconfig/network-scripts/ifcfg-xenbr0 << NETEOF
DEVICE=xenbr0
TYPE=OVSBridge
DEVICETYPE=ovs
ONBOOT=yes
BOOTPROTO=none
IPADDR=${REAL_IP}
NETMASK=${REAL_NETMASK}
GATEWAY=${REAL_GATEWAY}
DNS1=${REAL_DNS}
NETEOF
    # ifcfg-NIC: OVS port enslaved to bridge (no IP)
    cat > "/mnt/etc/sysconfig/network-scripts/ifcfg-${XCPNG_NIC}" << NETEOF
DEVICE=${XCPNG_NIC}
TYPE=OVSPort
DEVICETYPE=ovs
OVS_BRIDGE=xenbr0
ONBOOT=yes
BOOTPROTO=none
NETEOF
    log "Created OVS bridge xenbr0 with IP ${REAL_IP}, NIC ${XCPNG_NIC} as OVS port"

    # Set MANAGEMENT_INTERFACE in xensource-inventory
    sed -i "s/MANAGEMENT_INTERFACE=.*/MANAGEMENT_INTERFACE='xenbr0'/" /mnt/etc/xensource-inventory
    log "Set MANAGEMENT_INTERFACE=xenbr0"

    # -------------------------------------------------------------------------
    # Fix XAPI first-boot configuration (QEMU leaves wrong values)
    # -------------------------------------------------------------------------
    log "--- Fix XAPI first-boot configuration ---"

    # management.conf: XAPI reads this on first boot to configure networking.
    # QEMU install leaves eth0/dhcp/10.0.2.3 — must be real NIC/static/real IP.
    MGMT_CONF="/mnt/etc/firstboot.d/data/management.conf"
    if [ -f "$MGMT_CONF" ]; then
        cat > "$MGMT_CONF" << MGMTEOF
LABEL=${XCPNG_NIC}
MODE=static
IP=${REAL_IP}
NETMASK=${REAL_NETMASK}
GATEWAY=${REAL_GATEWAY}
DNS=${REAL_DNS}
MODEV6=none
MGMTEOF
        log "Fixed management.conf: ${XCPNG_NIC}/static/${REAL_IP}"
    else
        log "WARNING: management.conf not found at $MGMT_CONF"
    fi

    # default-storage.conf: QEMU leaves /dev/vda3 — must be real disk partition.
    STORAGE_CONF="/mnt/etc/firstboot.d/data/default-storage.conf"
    if [ -f "$STORAGE_CONF" ]; then
        REAL_DISK_NAME=$(basename "$TARGET_DISK")
        sed -i "s|/dev/vda|/dev/${REAL_DISK_NAME}|g" "$STORAGE_CONF"
        log "Fixed default-storage.conf: vda → ${REAL_DISK_NAME}"
    fi

    # Set hostname and default gateway
    echo "xcp-ng-poc" > /mnt/etc/hostname
    echo "GATEWAY=${REAL_GATEWAY}" > /mnt/etc/sysconfig/network

    # Set DNS
    cat > /mnt/etc/resolv.conf << DNSEOF
nameserver ${REAL_DNS}
nameserver 51.159.47.26
DNSEOF
    log "Network configured: ${XCPNG_NIC} (rescue: ${REAL_NIC_RESCUE}) / ${REAL_IP} / gw ${REAL_GATEWAY}"

    # -------------------------------------------------------------------------
    # Inject SSH authorized key for passwordless root access
    # -------------------------------------------------------------------------
    PUBKEY_FILE="$(dirname "$0")/authorized_keys.pub"
    if [ -f "$PUBKEY_FILE" ]; then
        mkdir -p /mnt/root/.ssh
        chmod 700 /mnt/root/.ssh
        cp "$PUBKEY_FILE" /mnt/root/.ssh/authorized_keys
        chmod 600 /mnt/root/.ssh/authorized_keys
        log "SSH public key injected into XCP-ng root account"
    else
        log "WARNING: No authorized_keys.pub found — XCP-ng will use password auth only"
    fi

    # -------------------------------------------------------------------------
    # Install pip3 + s3cmd for VM backup/restore to S3-compatible storage.
    # XCP-ng repos don't ship s3cmd, and pip is not pre-installed.
    # -------------------------------------------------------------------------
    log "--- Install pip3 + s3cmd ---"
    if ! chroot /mnt pip3 --version >/dev/null 2>&1; then
        chroot /mnt yum install -y python3-pip 2>&1 | tail -3 | tee -a "$LOG_FILE"
    fi
    if chroot /mnt pip3 --version >/dev/null 2>&1; then
        chroot /mnt pip3 install s3cmd 2>&1 | tail -3 | tee -a "$LOG_FILE"
        log "s3cmd installed: $(chroot /mnt s3cmd --version 2>&1 || true)"
    else
        log "WARNING: pip3 not available — s3cmd not installed"
    fi

    # -------------------------------------------------------------------------
    # Purge stale QEMU PIF data from XAPI first-boot state
    # -------------------------------------------------------------------------
    # Problem: The QEMU installer creates PIF entries for the virtio NIC
    # (MAC 52:54:00:12:34:56). These persist in XAPI's state.db after install.
    # On bare-metal first boot, XAPI creates xenbr1 from this stale entry
    # instead of creating xenbr0 from our ifcfg-xenbr0 config.
    #
    # Fix: Remove stale state.db so XAPI rebuilds it from scratch using
    # management.conf and ifcfg files on first boot.
    log "--- Purge stale QEMU PIF data ---"

    # Remove XAPI state.db — forces XAPI to rebuild from firstboot data
    if [ -f /mnt/var/lib/xcp/state.db ]; then
        rm -f /mnt/var/lib/xcp/state.db
        log "Removed stale state.db (XAPI will rebuild on first boot)"
    fi

    # Also remove any XAPI-generated network config that references QEMU MACs
    for f in /mnt/var/lib/xcp/networkd.db /mnt/var/xapi/networkd.db; do
        if [ -f "$f" ]; then
            rm -f "$f"
            log "Removed stale $f"
        fi
    done

    # Ensure firstboot scripts will run (they create PIF records from management.conf)
    # XAPI firstboot marks completion in /etc/firstboot.d/state/ — remove network-related marks
    for marker in /mnt/etc/firstboot.d/state/*network* /mnt/etc/firstboot.d/state/*xapi* /mnt/etc/firstboot.d/state/*management*; do
        if [ -f "$marker" ]; then
            rm -f "$marker"
            log "Removed firstboot marker: $(basename "$marker")"
        fi
    done
    log "XAPI PIF cleanup complete — first boot will use management.conf"

    # Clean up mounts
    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt/boot 2>/dev/null || true
    umount /mnt 2>/dev/null || true
fi

phase_end "Post-install chroot fixes"

# =============================================================================
# Step 8: Pre-reboot validation inside QEMU (Brainstorm Fix 5)
# =============================================================================
phase_start "Validation QEMU"
log "=== Step 8: Pre-reboot validation ==="
log "Booting installed system inside QEMU (no ISO)..."

# shellcheck disable=SC2054  # Commas are QEMU argument syntax, not array separators
VALIDATE_ARGS=(
    -enable-kvm
    -m 8192                                     # 8GB is enough for validation
    -smp 2
    -cpu host
    -drive "file=$TARGET_DISK,format=raw,if=virtio,cache=none"
    -netdev user,id=net0
    -device virtio-net-pci,netdev=net0
    -vnc 127.0.0.1:0
    -serial "file:/tmp/qemu-validate-serial.log"
    -display none
)

if [ "$BOOT_MODE" = "uefi" ] && [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
    VALIDATE_ARGS+=(-bios /usr/share/OVMF/OVMF_CODE.fd)
fi

qemu-system-x86_64 "${VALIDATE_ARGS[@]}" &
VALIDATE_PID=$!
log "Validation QEMU PID: $VALIDATE_PID (VNC :5900)"

# Wait for boot (give it 2 minutes)
log "Waiting for XCP-ng to boot inside QEMU..."
sleep 120

# Check serial log for signs of life
VALIDATE_OK=false
if [ -f /tmp/qemu-validate-serial.log ]; then
    log "--- Validation serial output (last 30 lines) ---"
    tail -30 /tmp/qemu-validate-serial.log | tee -a "$LOG_FILE"

    if grep -q "login:" /tmp/qemu-validate-serial.log; then
        log "SUCCESS: XCP-ng reached login prompt inside QEMU!"
        VALIDATE_OK=true
    elif grep -q "emergency\|dracut\|can.t find\|kernel panic" /tmp/qemu-validate-serial.log; then
        log "FAILURE: System dropped to emergency mode or kernel panic"
        log "Check serial log: /tmp/qemu-validate-serial.log"
        VALIDATE_OK=false
    else
        log "UNCERTAIN: No login prompt detected yet."
        VALIDATE_OK=false
    fi
fi

# Kill validation QEMU — it has served its purpose
log "Stopping validation QEMU (PID: $VALIDATE_PID)..."
kill "$VALIDATE_PID" 2>/dev/null || true
wait "$VALIDATE_PID" 2>/dev/null || true
log "Validation QEMU stopped."

if [ "$VALIDATE_OK" != "true" ]; then
    log "WARNING: Validation did not confirm login prompt."
    log "Proceeding anyway — check serial log for diagnostics."
fi

log ""
log "Full install log: $LOG_FILE"
log "Serial logs: $SERIAL_LOG, /tmp/qemu-validate-serial.log"
phase_end "Validation QEMU"

log ""
log "=== Installation complete — ready for bare-metal reboot ==="
log "Reboot via Scaleway API:"
log "  scw baremetal server stop <server-id> zone=fr-par-2"
log "  scw baremetal server start <server-id> boot-type=normal zone=fr-par-2"

print_timing_summary
