#!/bin/bash
set -euo pipefail

# Create agent VMs on a running XCP-ng host
#
# Orchestrates the full VM setup:
#   1. Verifies XCP-ng host is accessible
#   2. Finds or creates LVM storage
#   3. Creates internal VM network (10.0.0.0/24) with NAT
#   4. Downloads Debian netinst ISO
#   5. Builds preseed ISO for automated install
#   6. Creates ISO SR and attaches ISO
#   7. Finds Debian VM template
#   8. Creates golden-template VM with automated Debian install
#   9. Waits for install, ejects ISO
#  10. Provisions golden template (Node 22, Python 3, AI CLIs)
#  11. Clones template → agent VMs (unique IPs, SSH keys, hostnames)
#  12. Starts agent VMs and verifies SSH access
#  13. Summary
#
# Prerequisites:
#   - XCP-ng host running with SSH key access (provision-scaleway.sh injects the key)
#   - Fallback: sshpass + password auth if SSH_KEY_PATH is not set
#   - LVM SR available on /dev/sdb (or specify SR_UUID)
#   - Internet access on the host
#   - genisoimage available in repos (auto-installed if missing)
#
# Usage:
#   ./setup-vms.sh <server-ip> [sr-uuid]
#   SSH_KEY_PATH=~/.ssh/id_rsa ./setup-vms.sh <server-ip> [sr-uuid]
#
# Architecture:
#   Uses Debian preseed for unattended install inside a VM,
#   then post-install provisioning via SSH into the VM.
#   VMs live on a private internal network (10.0.0.0/24) with dom0 as
#   gateway. Dom0 does routed NAT (ip_forward + MASQUERADE on xenbr0)
#   so VMs can reach the internet. This avoids the OVS/br_netfilter
#   issue — traffic is routed through dom0's IP stack, not bridged.
#
# Networking:
#   An internal XCP-ng network ("vm-internal") with a Linux bridge is
#   created for VM traffic. Dom0 gets 10.0.0.1 on this bridge.
#   VMs are only reachable from dom0 (no public IPs needed).
#
# IP layout:
#   SERVER_IP  — dom0 public (e.g. 51.159.105.223) on xenbr0
#   10.0.0.1   — dom0 internal gateway on vm-internal bridge
#   10.0.0.100 — golden-template (during install)
#   10.0.0.101 — agent-claude
#   10.0.0.102 — agent-gemini
#   10.0.0.103 — orchestrator

SERVER_IP="${1:-}"
SR_UUID="${2:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/ai-workstation}"

if [ -z "$SERVER_IP" ]; then
    echo "Usage: $0 <server-ip> [sr-uuid]"
    exit 1
fi

# SSH configuration: prefer key-based auth (provision-scaleway.sh injects the key).
# Falls back to sshpass + password if no key found.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if [ -f "$SSH_KEY_PATH" ]; then
    SSH_CMD="ssh $SSH_OPTS -i $SSH_KEY_PATH -o IdentitiesOnly=yes root@$SERVER_IP"
else
    SSH_OPTS="$SSH_OPTS -o PubkeyAuthentication=no"
    SSH_CMD="sshpass -p changeme ssh $SSH_OPTS root@$SERVER_IP"
fi

# --- Timing instrumentation ---
# Records wall-clock duration of each step for the article.
# Usage: timer_start "Step name" at the beginning, timer_end at the end.
# Final summary printed by timer_summary.
TIMING_LOG="/tmp/setup-vms-timing-$(date +%Y%m%d-%H%M%S).log"
PIPELINE_START=$(date +%s)
declare -a TIMING_NAMES=()
declare -a TIMING_DURATIONS=()
STEP_START=0
STEP_NAME=""

timer_start() {
    STEP_NAME="$1"
    STEP_START=$(date +%s)
}

timer_end() {
    local now
    now=$(date +%s)
    local elapsed=$((now - STEP_START))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    TIMING_NAMES+=("$STEP_NAME")
    TIMING_DURATIONS+=("$elapsed")
    printf "  [timing] %s: %dm%02ds\n" "$STEP_NAME" "$mins" "$secs"
    printf "%s\t%d\t%dm%02ds\n" "$STEP_NAME" "$elapsed" "$mins" "$secs" >> "$TIMING_LOG"
}

timer_summary() {
    local total=$(($(date +%s) - PIPELINE_START))
    local total_mins=$((total / 60))
    local total_secs=$((total % 60))
    echo ""
    echo "=== Timing Summary ==="
    printf "%-40s %s\n" "Step" "Duration"
    printf "%-40s %s\n" "----" "--------"
    for i in "${!TIMING_NAMES[@]}"; do
        local d=${TIMING_DURATIONS[$i]}
        printf "%-40s %dm%02ds\n" "${TIMING_NAMES[$i]}" "$((d/60))" "$((d%60))"
    done
    printf "%-40s %s\n" "----" "--------"
    printf "%-40s %dm%02ds\n" "TOTAL" "$total_mins" "$total_secs"
    echo ""
    echo "  Timing log saved to: $TIMING_LOG"
    # Append summary to log
    printf "\nTOTAL\t%d\t%dm%02ds\n" "$total" "$total_mins" "$total_secs" >> "$TIMING_LOG"
}

# Re-apply dom0 gateway IP on the internal bridge. XAPI resets the bridge
# during vm-start/stop, dropping manually-added addresses.
ensure_gateway_ip() {
    $SSH_CMD bash -s 2>/dev/null << GWEOF
BRIDGE=$INTERNAL_BRIDGE
if ! ip addr show dev \$BRIDGE 2>/dev/null | grep -q "10.0.0.1/24"; then
    ip addr add 10.0.0.1/24 dev \$BRIDGE
    ip link set \$BRIDGE up
    echo "  Gateway IP re-applied on \$BRIDGE"
fi
GWEOF
}

# --- Step 0: Neutralize Scaleway's SSH stdout suppression ---
# Scaleway provisions XCP-ng with a .bashrc trap that kills non-interactive
# non-TTY SSH sessions (exit 0), preventing command output from reaching us.
# A background agent continuously re-adds the trap, so we remove it and lock
# the file with chattr +i to prevent re-injection.
echo "=== Step 0: Fix SSH access ==="
timer_start "Step 0: Fix SSH access"
# Use TTY mode (-tt) for the .bashrc fix since the trap targets non-TTY sessions
if [ -f "$SSH_KEY_PATH" ]; then
    ssh -tt $SSH_OPTS -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes root@$SERVER_IP \
        "chattr -i /root/.bashrc 2>/dev/null; sed -i '/exit 0/d' /root/.bashrc; sed -i '/^top()/d' /root/.bashrc; sed -i '/^crontab()/d' /root/.bashrc; chattr +i /root/.bashrc; exit" 2>/dev/null
else
    sshpass -p changeme ssh -tt $SSH_OPTS root@$SERVER_IP \
        "chattr -i /root/.bashrc 2>/dev/null; sed -i '/exit 0/d' /root/.bashrc; sed -i '/^top()/d' /root/.bashrc; sed -i '/^crontab()/d' /root/.bashrc; chattr +i /root/.bashrc; exit" 2>/dev/null
fi
sleep 2
if ! $SSH_CMD "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot get SSH stdout from $SERVER_IP after .bashrc fix"
    exit 1
fi
echo "  SSH access verified."

timer_end

# --- Step 1: Verify XCP-ng is running ---
echo "=== Step 1: Verify XCP-ng host ==="
timer_start "Step 1: Verify XCP-ng host"
if ! $SSH_CMD "xe host-list --minimal" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to XCP-ng at $SERVER_IP"
    echo "  Try: ssh -i $SSH_KEY_PATH root@$SERVER_IP"
    exit 1
fi
HOST_UUID=$($SSH_CMD "xe host-list --minimal" 2>/dev/null)
echo "  Host: $HOST_UUID"

timer_end

# --- Step 2: Find or create storage ---
echo ""
echo "=== Step 2: Find storage ==="
timer_start "Step 2: Find storage"
if [ -z "$SR_UUID" ]; then
    SR_UUID=$($SSH_CMD "xe sr-list type=lvm --minimal" 2>/dev/null)
fi
if [ -z "$SR_UUID" ]; then
    echo "  No LVM SR found, creating on /dev/sdb..."
    SR_UUID=$($SSH_CMD "xe sr-create name-label='VM Storage' type=lvm content-type=user device-config:device=/dev/sdb host-uuid=$HOST_UUID" 2>/dev/null)
fi
if [ -z "$SR_UUID" ]; then
    echo "ERROR: Failed to find or create LVM SR"
    exit 1
fi
SR_SIZE=$($SSH_CMD "xe sr-param-get uuid=$SR_UUID param-name=physical-size" 2>/dev/null)
echo "  SR: $SR_UUID ($(echo "$SR_SIZE / 1073741824" | bc)GB)"

timer_end

# --- Step 3: Create internal VM network ---
echo ""
echo "=== Step 3: Create internal VM network ==="
timer_start "Step 3: Create internal VM network"
# Private 10.0.0.0/24 network with dom0 as NAT gateway.
# Uses routed NAT (ip_forward + MASQUERADE) — traffic goes through dom0's
# IP stack, not bridged through OVS, so br_netfilter is irrelevant.
INTERNAL_SUBNET="10.0.0"
GW="${INTERNAL_SUBNET}.1"
DNS="62.210.16.6"  # Scaleway DNS
GOLDEN_IP="${INTERNAL_SUBNET}.100"

$SSH_CMD bash -s 2>/dev/null << 'NETEOF'
# Create internal network if it doesn't exist
EXISTING=$(xe network-list name-label=vm-internal --minimal 2>/dev/null)
if [ -n "$EXISTING" ]; then
    echo "NETWORK=$EXISTING"
    BRIDGE=$(xe network-param-get uuid=$EXISTING param-name=bridge)
    echo "BRIDGE=$BRIDGE"
else
    NET=$(xe network-create name-label=vm-internal name-description="Private VM network (10.0.0.0/24)")
    echo "NETWORK=$NET"
    BRIDGE=$(xe network-param-get uuid=$NET param-name=bridge)
    echo "BRIDGE=$BRIDGE"
fi

# Persist dom0 gateway IP on the internal bridge via ifcfg file.
# XAPI resets bridges on every vm-start/stop, dropping manually-added IPs.
# An ifcfg file makes NetworkManager/ifup re-apply the IP automatically.
cat > /etc/sysconfig/network-scripts/ifcfg-$BRIDGE << IFCFG
DEVICE=$BRIDGE
BOOTPROTO=none
ONBOOT=yes
IPADDR=10.0.0.1
NETMASK=255.255.255.0
IFCFG
# Apply immediately
ip addr add 10.0.0.1/24 dev $BRIDGE 2>/dev/null || true
ip link set $BRIDGE up

# Persist IP forwarding and NAT across reboots
echo 1 > /proc/sys/net/ipv4/ip_forward
grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf

# Get the outgoing interface (management bridge, e.g. xenbr0)
OUT_IF=$(ip route | awk '/default/{print $5}')
iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o $OUT_IF -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $OUT_IF -j MASQUERADE
# Insert FORWARD rules at the TOP of the chain — XCP-ng's RH-Firewall-1-INPUT
# chain jumps early in FORWARD and ends with REJECT all, so appended rules
# never execute.
iptables -C FORWARD -i $BRIDGE -o $OUT_IF -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i $BRIDGE -o $OUT_IF -j ACCEPT
iptables -C FORWARD -i $OUT_IF -o $BRIDGE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 2 -i $OUT_IF -o $BRIDGE -m state --state RELATED,ESTABLISHED -j ACCEPT
# Save iptables so rules persist across reboots
service iptables save 2>/dev/null || true
NETEOF

# Capture the network UUID and bridge name from the output
INTERNAL_NET_INFO=$($SSH_CMD "xe network-list name-label=vm-internal --minimal" 2>/dev/null)
INTERNAL_BRIDGE=$($SSH_CMD "xe network-param-get uuid=$INTERNAL_NET_INFO param-name=bridge" 2>/dev/null)
echo "  Internal network: $INTERNAL_NET_INFO ($INTERNAL_BRIDGE)"
echo "  Dom0 gateway: $GW on $INTERNAL_BRIDGE"
echo "  Golden template: $GOLDEN_IP"
echo "  Agent VMs: ${INTERNAL_SUBNET}.101 - ${INTERNAL_SUBNET}.103"

timer_end

# --- Step 4: Download Debian ISO ---
echo ""
echo "=== Step 4: Download Debian ISO ==="
timer_start "Step 4: Download Debian ISO"
DEBIAN_ISO=$($SSH_CMD bash -s 2>/dev/null << 'FINDISO'
# Check if we already have an ISO
EXISTING=$(find /var/opt/isos -name 'debian-*.iso' -size +100M 2>/dev/null | head -1)
if [ -n "$EXISTING" ]; then
    echo "$EXISTING"
    exit 0
fi

mkdir -p /var/opt/isos
cd /var/opt/isos

# Use Debian 12 Bookworm (stable, well-tested preseed, no Trixie pitfalls)
# Bookworm is now oldstable — ISOs live in the archive
DEBIAN_VER="12.13.0"
ISO_NAME="debian-${DEBIAN_VER}-amd64-netinst.iso"
ISO_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VER}/amd64/iso-cd/${ISO_NAME}"

curl -sL -o "$ISO_NAME" "$ISO_URL"
if [ ! -s "$ISO_NAME" ]; then
    echo "ERROR: Could not download Debian 12 netinst ISO from $ISO_URL"
    exit 1
fi
echo "/var/opt/isos/$ISO_NAME"
FINDISO
)

if [ -z "$DEBIAN_ISO" ] || echo "$DEBIAN_ISO" | grep -q "ERROR"; then
    echo "ERROR: Failed to download Debian ISO"
    exit 1
fi
ISO_BASENAME=$(basename "$DEBIAN_ISO")
echo "  ISO: $ISO_BASENAME"

timer_end

# --- Step 5: Build preseed ISO ---
echo ""
echo "=== Step 5: Build preseed ISO ==="
timer_start "Step 5: Build preseed ISO"
VM_IP="$GOLDEN_IP"
VM_GW="$GW"
VM_DNS="$DNS"
# VMs use the internal network, not the management network
NETWORK="$INTERNAL_NET_INFO"
$SSH_CMD bash -s "$VM_IP" "$VM_GW" "$VM_DNS" 2>/dev/null << 'PRESEEDEOF'
VM_IP="$1"; VM_GW="$2"; VM_DNS="$3"

# Skip if preseed ISO already exists and is recent
if [ -f /var/opt/isos/debian-12-preseed.iso ] && \
   [ "$(find /var/opt/isos/debian-12-preseed.iso -mmin -60 2>/dev/null)" ]; then
    echo "Preseed ISO already up-to-date"
    exit 0
fi

DEBIAN_ISO=$(find /var/opt/isos -name 'debian-12*-amd64-netinst.iso' -size +100M 2>/dev/null | head -1)
if [ -z "$DEBIAN_ISO" ]; then
    echo "ERROR: No Debian netinst ISO found"
    exit 1
fi

# Write preseed config (Debian 12 Bookworm)
mkdir -p /var/opt/preseed
cat > /var/opt/preseed/preseed.cfg << PCFG
# Locale and keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# Network: static public IP (borrowed from server's /24, pure L2)
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string $VM_IP
d-i netcfg/get_netmask string 255.255.255.0
d-i netcfg/get_gateway string $VM_GW
d-i netcfg/get_nameservers string $VM_DNS
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string golden-template
d-i netcfg/get_domain string local

# Mirror
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# Apt configuration: answer all apt-setup questions to avoid hangs
d-i apt-setup/use_mirror boolean true
d-i apt-setup/services-select multiselect security, updates
d-i apt-setup/security_host string security.debian.org
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/non-free boolean false
d-i apt-setup/contrib boolean false
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false

# Clock
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/ntp boolean false

# Partitioning: single ext4 root, no swap (VMs don't need it)
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Root password (will be changed post-install)
d-i passwd/root-login boolean true
d-i passwd/root-password password changeme
d-i passwd/root-password-again password changeme
d-i passwd/make-user boolean false

# Package selection: minimal + SSH
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server curl wget git sudo
d-i pkgsel/upgrade string safe-upgrade
popularity-contest popularity-contest/participate boolean false

# GRUB
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string default

# Post-install:
# - Allow root SSH login (Bookworm defaults to prohibit-password)
# - Remove apt proxy config (preseed artifact)
# - Rewrite /etc/network/interfaces with static IP (ifupdown, Bookworm default)
# - Detect NIC name from installer: check /target/etc/network/interfaces for the
#   interface name the installer used, or fall back to the first non-lo in /sys
d-i preseed/late_command string \
    in-target sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; \
    in-target rm -f /etc/apt/apt.conf; \
    NIC=\$(ls /sys/class/net/ | grep -v lo | head -1); \
    if [ -z "\$NIC" ]; then NIC=ens3; fi; \
    echo "auto lo" > /target/etc/network/interfaces; \
    echo "iface lo inet loopback" >> /target/etc/network/interfaces; \
    echo "" >> /target/etc/network/interfaces; \
    echo "auto \$NIC" >> /target/etc/network/interfaces; \
    echo "iface \$NIC inet static" >> /target/etc/network/interfaces; \
    echo "  address $VM_IP/24" >> /target/etc/network/interfaces; \
    echo "  gateway $VM_GW" >> /target/etc/network/interfaces; \
    echo "  dns-nameservers $VM_DNS" >> /target/etc/network/interfaces

# Finish: power off so we know the install is done.
# The d-i exit/poweroff directive is unreliable on Bookworm — the installer
# often reboots instead. The polling loop handles both: it checks for halted
# state, and if the VM reboots instead, it detects SSH readiness as a fallback.
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
PCFG

# Install genisoimage if not present (XCP-ng doesn't ship it by default)
if ! command -v genisoimage &>/dev/null; then
    yum install -y genisoimage >/dev/null 2>&1
fi

# Remaster ISO with preseed
rm -rf /tmp/iso-rebuild
mkdir -p /tmp/iso-rebuild/work /tmp/iso-rebuild/mount
mount -o loop "$DEBIAN_ISO" /tmp/iso-rebuild/mount
cp -a /tmp/iso-rebuild/mount/* /tmp/iso-rebuild/work/
cp -a /tmp/iso-rebuild/mount/.disk /tmp/iso-rebuild/work/ 2>/dev/null
umount /tmp/iso-rebuild/mount

cp /var/opt/preseed/preseed.cfg /tmp/iso-rebuild/work/
chmod +w /tmp/iso-rebuild/work/isolinux/isolinux.cfg
cat > /tmp/iso-rebuild/work/isolinux/isolinux.cfg << 'ISOCFG'
default auto
timeout 3
prompt 0

label auto
  kernel /install.amd/vmlinuz
  append auto=true priority=critical preseed/file=/cdrom/preseed.cfg vga=788 initrd=/install.amd/initrd.gz --- quiet
ISOCFG

chmod +w /tmp/iso-rebuild/work/isolinux/isolinux.bin
genisoimage -r -J -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -o /var/opt/isos/debian-12-preseed.iso /tmp/iso-rebuild/work/ 2>/dev/null
isohybrid /var/opt/isos/debian-12-preseed.iso 2>/dev/null || true
rm -rf /tmp/iso-rebuild
echo "Preseed ISO built: $(ls -lh /var/opt/isos/debian-12-preseed.iso | awk '{print $5}')"
PRESEEDEOF

timer_end

# --- Step 6: Create ISO SR ---
echo ""
echo "=== Step 6: Create ISO SR ==="
timer_start "Step 6: Create ISO SR"
ISO_SR=$($SSH_CMD bash -s 2>/dev/null << 'ISOSR'
# Check if Local ISOs SR already exists
EXISTING=$(xe sr-list name-label="Local ISOs" --minimal 2>/dev/null)
if [ -n "$EXISTING" ]; then
    xe sr-scan uuid=$EXISTING 2>/dev/null
    echo "$EXISTING"
    exit 0
fi
HOST_UUID=$(xe host-list --minimal)
SR=$(xe sr-create name-label="Local ISOs" type=iso \
    device-config:location=/var/opt/isos \
    device-config:legacy_mode=true \
    content-type=iso host-uuid=$HOST_UUID)
xe sr-scan uuid=$SR 2>/dev/null
echo "$SR"
ISOSR
)
echo "  ISO SR: $ISO_SR"

# Get ISO VDI UUID
ISO_VDI=$($SSH_CMD "xe vdi-list sr-uuid=$ISO_SR name-label=debian-12-preseed.iso --minimal" 2>/dev/null)
if [ -z "$ISO_VDI" ]; then
    echo "ERROR: Preseed ISO VDI not found — ISO may not have been built correctly"
    exit 1
fi
echo "  ISO VDI: $ISO_VDI (debian-12-preseed.iso)"

timer_end

# --- Step 7: Find Debian template ---
echo ""
echo "=== Step 7: Find Debian template ==="
timer_start "Step 7: Find Debian template"
# Use Debian Bookworm 12 template (always available in XCP-ng 8.3)
# Debian Bookworm 12 template sets sensible HVM defaults for the VM
TEMPLATE=$($SSH_CMD "xe template-list name-label='Debian Bookworm 12' --minimal" 2>/dev/null)
if [ -z "$TEMPLATE" ]; then
    TEMPLATE=$($SSH_CMD "xe template-list name-label='Debian Bullseye 11' --minimal" 2>/dev/null)
fi
if [ -z "$TEMPLATE" ]; then
    echo "ERROR: No supported Debian template found on host"
    exit 1
fi
echo "  Template: $TEMPLATE"

timer_end

# --- Step 8: Create VMs ---
echo ""
echo "=== Step 8: Create VMs ==="
timer_start "Step 8: Create golden-template VM"
# Use the internal VM network created in Step 3
NETWORK="$INTERNAL_NET_INFO"
BRIDGE="$INTERNAL_BRIDGE"
echo "  Network: $NETWORK ($BRIDGE)"

create_vm() {
    local NAME=$1
    local RAM_GB=$2
    local VCPUS=$3
    local DISK_GB=$4

    echo "  Creating $NAME (${RAM_GB}GB RAM, ${VCPUS} vCPUs, ${DISK_GB}GB disk)..." >&2

    # Check if VM already exists
    EXISTING=$($SSH_CMD "xe vm-list name-label=$NAME --minimal" 2>/dev/null)
    if [ -n "$EXISTING" ]; then
        echo "    Already exists: $EXISTING" >&2
        echo "$EXISTING"
        return
    fi

    VM_UUID=$($SSH_CMD bash -s 2>/dev/null << VMEOF
TEMPLATE="$TEMPLATE"
SR="$SR_UUID"
NAME="$NAME"
RAM_GB=$RAM_GB
VCPUS=$VCPUS
DISK_GB=$DISK_GB
NETWORK="$NETWORK"

VM=\$(xe vm-install template=\$TEMPLATE new-name-label=\$NAME sr-uuid=\$SR)
xe vm-memory-limits-set uuid=\$VM static-min=\${RAM_GB}GiB static-max=\${RAM_GB}GiB dynamic-min=\${RAM_GB}GiB dynamic-max=\${RAM_GB}GiB
xe vm-param-set uuid=\$VM VCPUs-max=\$VCPUS VCPUs-at-startup=\$VCPUS
xe vm-param-set uuid=\$VM name-description="Agent VM - Debian Bookworm 12"

# Fix boot config: Debian Bookworm template sets UEFI + eliloader which
# drops to UEFI shell instead of booting the ISO. Switch to BIOS + CD boot.
xe vm-param-set uuid=\$VM PV-bootloader=""
xe vm-param-set uuid=\$VM HVM-boot-policy="BIOS order"
xe vm-param-set uuid=\$VM HVM-boot-params:firmware=bios
xe vm-param-set uuid=\$VM HVM-boot-params:order=dc
xe vm-param-set uuid=\$VM platform:device-model=qemu-upstream-compat

# Resize disk
VDI=\$(xe vbd-list vm-uuid=\$VM type=Disk params=vdi-uuid --minimal)
xe vdi-resize uuid=\$VDI disk-size=\${DISK_GB}GiB

# Attach preseed ISO for automated Debian install
xe vm-cd-add uuid=\$VM cd-name="debian-12-preseed.iso" device=3 >/dev/null

# Add network
xe vif-create vm-uuid=\$VM network-uuid=\$NETWORK device=0 >/dev/null

echo \$VM
VMEOF
    )
    echo "    UUID: $VM_UUID" >&2
    echo "$VM_UUID"
}

timer_end

# --- Step 9: Install golden template ---
echo ""
echo "=== Step 9: Install golden template ==="
timer_start "Step 9: Debian install (preseed)"
VM_GOLDEN=$(create_vm "golden-template" 4 2 40)



# Start the golden template VM — preseed handles unattended Debian install
echo "  Starting golden-template install (automated via preseed)..."
$SSH_CMD "xe vm-start uuid=$VM_GOLDEN" 2>/dev/null

sleep 3
ensure_gateway_ip

# Wait for install to complete. The preseed requests poweroff, but Bookworm
# sometimes reboots instead. Detect either: halted state OR SSH on the
# installed OS (which means the installer finished and the VM rebooted).
echo "  Waiting for install to finish..."
INSTALL_DONE=0
MAX_POLLS=120   # ~60 minutes at 30s intervals
for _ in $(seq 1 "$MAX_POLLS"); do
    STATE=$($SSH_CMD "xe vm-param-get uuid=$VM_GOLDEN param-name=power-state" 2>/dev/null)
    if [ "$STATE" = "halted" ]; then
        echo "  Install complete — VM powered off."
        INSTALL_DONE=1
        break
    fi
    # Check if the VM rebooted into the installed OS (SSH available)
    if $SSH_CMD "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o PasswordAuthentication=yes root@$GOLDEN_IP 'true'" 2>/dev/null; then
        echo "  Install complete — VM rebooted into installed OS (SSH ready)."
        # Shut it down so we can eject the CD and proceed normally
        $SSH_CMD "xe vm-shutdown uuid=$VM_GOLDEN" 2>/dev/null
        sleep 5
        INSTALL_DONE=1
        break
    fi
    sleep 30
done
if [ "$INSTALL_DONE" -ne 1 ]; then
    echo "ERROR: golden-template install did not complete within 60 minutes"
    exit 1
fi

# Eject ISO — boot from disk next time
$SSH_CMD "xe vm-cd-eject uuid=$VM_GOLDEN" 2>/dev/null
# Change boot order to disk first
$SSH_CMD "xe vm-param-set uuid=$VM_GOLDEN HVM-boot-params:order=dc" 2>/dev/null

timer_end

# Inject dom0's SSH key into the golden template disk (VM is halted).
# XCP-ng doesn't ship sshpass, so key-based auth is the only option.
timer_start "Step 9b: SSH key injection"
echo "  Injecting dom0 SSH key into golden template disk..."
$SSH_CMD bash -s 2>/dev/null << 'KEYEOF'
# Generate dom0 SSH key if needed
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa -q
KEYEOF
$SSH_CMD bash -s "$VM_GOLDEN" 2>/dev/null << 'MOUNTEOF'
VM_UUID="$1"
VDI=$(xe vbd-list vm-uuid=$VM_UUID type=Disk params=vdi-uuid --minimal)
DOM0=$(xe vm-list is-control-domain=true --minimal)
VBD=$(xe vbd-create vm-uuid=$DOM0 vdi-uuid=$VDI device=autodetect)
xe vbd-plug uuid=$VBD
DEV=/dev/$(xe vbd-param-get uuid=$VBD param-name=device)
kpartx -av $DEV >/dev/null 2>&1
sleep 1
# Find first partition (root)
PART1=$(ls /dev/mapper/*p1 2>/dev/null | head -1)
[ -z "$PART1" ] && PART1=$(ls /dev/mapper/*1 2>/dev/null | grep -v control | head -1)
mkdir -p /tmp/vmdisk
mount $PART1 /tmp/vmdisk
mkdir -p /tmp/vmdisk/root/.ssh
cat ~/.ssh/id_rsa.pub >> /tmp/vmdisk/root/.ssh/authorized_keys
chmod 700 /tmp/vmdisk/root/.ssh
chmod 600 /tmp/vmdisk/root/.ssh/authorized_keys
echo "  Key injected"
umount /tmp/vmdisk
kpartx -dv $DEV >/dev/null 2>&1
xe vbd-unplug uuid=$VBD
xe vbd-destroy uuid=$VBD
MOUNTEOF

timer_end

# --- Step 10: Provision golden template with tools ---
echo ""
echo "=== Step 10: Provision golden template ==="
timer_start "Step 10: Provision tools (Node, Python, AI CLIs)"
echo "  Starting golden-template for tool installation..."
$SSH_CMD "xe vm-start uuid=$VM_GOLDEN" 2>/dev/null
sleep 3
ensure_gateway_ip

# Wait for SSH to be ready inside the golden template
GT_IP="$GOLDEN_IP"
echo "  Waiting for SSH on $GT_IP..."
SSH_OK=0
for i in $(seq 1 60); do
    if $SSH_CMD "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@$GT_IP 'true'" 2>/dev/null; then
        echo "  SSH ready after ${i} attempts."
        SSH_OK=1
        break
    fi
    # Every 10 attempts, print diagnostic
    if (( i % 10 == 0 )); then
        echo "  Still waiting ($i/60)... checking VM state:"
        $SSH_CMD "ping -c1 -W2 $GT_IP >/dev/null 2>&1 && echo '    ping: OK' || echo '    ping: FAIL'"
        $SSH_CMD "nc -z -w2 $GT_IP 22 >/dev/null 2>&1 && echo '    port 22: OPEN' || echo '    port 22: CLOSED'" 2>/dev/null
    fi
    sleep 5
done

if [ "$SSH_OK" -ne 1 ]; then
    echo "  ERROR: SSH to $GT_IP never became ready after 5 minutes."
    echo "  Diagnostics from dom0:"
    $SSH_CMD "ping -c2 $GT_IP 2>/dev/null; nc -zv -w3 $GT_IP 22 2>&1; xe vm-param-get uuid=$VM_GOLDEN param-name=power-state 2>/dev/null" 2>/dev/null
    exit 1
fi

# Install tools inside the golden template via SSH through dom0
echo "  Installing development tools and AI CLIs..."
$SSH_CMD bash -s "$GT_IP" 2>/dev/null << 'TOOLSEOF'
GT_IP="$1"
ssh -o StrictHostKeyChecking=no root@$GT_IP bash << 'INNEREOF'
set -e

# Remove stale apt proxy if present (preseed artifact)
rm -f /etc/apt/apt.conf

# Install base development tools
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git python3 python3-pip python3-venv jq curl build-essential ca-certificates gnupg

# Install Node.js 22 via NodeSource
if ! command -v node &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs
fi

echo "Node: $(node --version), npm: $(npm --version), Python: $(python3 --version), git: $(git --version)"

# Install AI CLI tools
npm install -g @anthropic-ai/claude-code 2>/dev/null || echo "Claude Code install failed (non-fatal)"
npm install -g @google/gemini-cli 2>/dev/null || echo "Gemini CLI install failed (non-fatal)"

echo "Tools installed successfully."
INNEREOF
TOOLSEOF

echo "  Shutting down golden template..."
$SSH_CMD "xe vm-shutdown uuid=$VM_GOLDEN" 2>/dev/null
# Wait for shutdown
for i in $(seq 1 20); do
    STATE=$($SSH_CMD "xe vm-param-get uuid=$VM_GOLDEN param-name=power-state" 2>/dev/null)
    [ "$STATE" = "halted" ] && break
    sleep 5
done
echo "  Golden template provisioned and halted. Ready for cloning."

timer_end

# --- Step 11: Clone golden template → agent VMs ---
echo ""
echo "=== Step 11: Clone agent VMs ==="
timer_start "Step 11: Clone agent VMs"

# VM definitions: name:ram_gb:vcpus:ip_last_octet
VM_DEFS=(
    "agent-claude:8:4:101"
    "agent-gemini:8:4:102"
    "orchestrator:2:2:103"
)

for VM_DEF in "${VM_DEFS[@]}"; do
    IFS=: read -r VM_NAME RAM VCPUS IP_OFFSET <<< "$VM_DEF"

    EXISTING=$($SSH_CMD "xe vm-list name-label=$VM_NAME --minimal" 2>/dev/null)
    if [ -n "$EXISTING" ]; then
        echo "  $VM_NAME already exists: $EXISTING"
        continue
    fi

    CLONE=$($SSH_CMD "xe vm-copy vm=$VM_GOLDEN new-name-label=$VM_NAME sr-uuid=$SR_UUID" 2>/dev/null)
    echo "  Cloned $VM_NAME: $CLONE"

    # Resize RAM and vCPUs
    $SSH_CMD "xe vm-memory-limits-set uuid=$CLONE static-min=${RAM}GiB static-max=${RAM}GiB dynamic-min=${RAM}GiB dynamic-max=${RAM}GiB" 2>/dev/null
    $SSH_CMD "xe vm-param-set uuid=$CLONE VCPUs-max=$VCPUS VCPUs-at-startup=$VCPUS" 2>/dev/null

    # Assign unique IP by mounting the clone's disk and editing network config.
    # Without this, every clone boots with the golden template's IP → conflicts.
    VM_IP="${INTERNAL_SUBNET}.${IP_OFFSET}"
    echo "  Assigning IP $VM_IP to $VM_NAME..."
    $SSH_CMD bash -s "$CLONE" "$VM_NAME" "$VM_IP" "$GW" 2>/dev/null << 'IPEOF'
CLONE_UUID="$1"; VM_NAME="$2"; VM_IP="$3"; GW="$4"

VDI=$(xe vbd-list vm-uuid=$CLONE_UUID type=Disk params=vdi-uuid --minimal)
# Plug the VDI temporarily to access it from dom0
TMP_VM=$(xe vm-list is-control-domain=true --minimal)
TMP_VBD=$(xe vbd-create vm-uuid=$TMP_VM vdi-uuid=$VDI device=autodetect type=Disk)
xe vbd-plug uuid=$TMP_VBD

# XCP-ng LVM-backed SM uses /dev/sm/backend/... paths that don't create
# partition device nodes automatically. Use kpartx to map partitions.
DEVICE=$(xe vbd-param-get uuid=$TMP_VBD param-name=device)
DEV="/dev/${DEVICE}"
kpartx -av $DEV >/dev/null 2>&1
sleep 1
# Find root partition (first partition mapper device)
PART1=$(ls /dev/mapper/*p1 2>/dev/null | head -1)
[ -z "$PART1" ] && PART1=$(ls /dev/mapper/*1 2>/dev/null | grep -v control | head -1)

MOUNT="/tmp/vm-edit-$$"
mkdir -p "$MOUNT"
mount "$PART1" "$MOUNT"

# Update /etc/network/interfaces
if [ -f "$MOUNT/etc/network/interfaces" ]; then
    sed -i "s|address .*|address ${VM_IP}/24|" "$MOUNT/etc/network/interfaces"
    sed -i "s|gateway .*|gateway ${GW}|" "$MOUNT/etc/network/interfaces"
fi

# Update hostname
echo "$VM_NAME" > "$MOUNT/etc/hostname"
sed -i "s/golden-template/$VM_NAME/g" "$MOUNT/etc/hosts"

# Inject dom0's SSH public key for passwordless access
if [ -f /root/.ssh/id_rsa.pub ]; then
    mkdir -p "$MOUNT/root/.ssh"
    cat /root/.ssh/id_rsa.pub >> "$MOUNT/root/.ssh/authorized_keys"
    chmod 700 "$MOUNT/root/.ssh"
    chmod 600 "$MOUNT/root/.ssh/authorized_keys"
fi

# Cleanup
umount "$MOUNT"
rmdir "$MOUNT"
kpartx -dv $DEV >/dev/null 2>&1
xe vbd-unplug uuid=$TMP_VBD
xe vbd-destroy uuid=$TMP_VBD

echo "  $VM_NAME: IP=$VM_IP hostname=$VM_NAME ssh-key=injected"
IPEOF
done

timer_end

# --- Step 12: Start agent VMs ---
echo ""
echo "=== Step 12: Start agent VMs ==="
timer_start "Step 12: Start VMs + verify SSH"
# Generate SSH key on dom0 if missing (for passwordless access to VMs)
$SSH_CMD '[ -f /root/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q' 2>/dev/null

for VM_DEF in "${VM_DEFS[@]}"; do
    IFS=: read -r VM_NAME RAM VCPUS IP_OFFSET <<< "$VM_DEF"
    VM_IP="${INTERNAL_SUBNET}.${IP_OFFSET}"
    VM_UUID=$($SSH_CMD "xe vm-list name-label=$VM_NAME --minimal" 2>/dev/null)

    # Start the VM
    STATE=$($SSH_CMD "xe vm-param-get uuid=$VM_UUID param-name=power-state" 2>/dev/null)
    if [ "$STATE" != "running" ]; then
        $SSH_CMD "xe vm-start uuid=$VM_UUID" 2>/dev/null
        echo "  Started $VM_NAME ($VM_IP)"
    else
        echo "  $VM_NAME already running ($VM_IP)"
    fi
done

ensure_gateway_ip

# Wait for VMs to boot and verify SSH
echo "  Waiting for VMs to boot..."
sleep 15
for VM_DEF in "${VM_DEFS[@]}"; do
    IFS=: read -r VM_NAME RAM VCPUS IP_OFFSET <<< "$VM_DEF"
    VM_IP="${INTERNAL_SUBNET}.${IP_OFFSET}"
    if $SSH_CMD "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$VM_IP 'hostname'" 2>/dev/null | grep -q "$VM_NAME"; then
        echo "  $VM_NAME ($VM_IP): SSH OK"
    else
        echo "  $VM_NAME ($VM_IP): SSH not ready yet (try again in a minute)"
    fi
done

timer_end

# --- Step 13: Summary ---
echo ""
echo "=== VM Summary ==="
$SSH_CMD "xe vm-list is-control-domain=false params=uuid,name-label,memory-static-max,VCPUs-at-startup,power-state" 2>/dev/null

echo ""
echo "=== Done ==="
echo "  Golden template installed with Debian Bookworm 12, Node 22, Python 3, AI CLIs."
echo "  Agent VMs cloned with unique IPs on internal network (10.0.0.0/24):"
for VM_DEF in "${VM_DEFS[@]}"; do
    IFS=: read -r VM_NAME RAM VCPUS IP_OFFSET <<< "$VM_DEF"
    echo "    ssh root@${INTERNAL_SUBNET}.${IP_OFFSET}  ($VM_NAME)"
done
echo "  Next: install dev tools, inject API keys, assign tasks."

timer_summary
