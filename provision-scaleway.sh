#!/bin/bash
set -euo pipefail

# Provision a Scaleway Elastic Metal server and install XCP-ng end-to-end
#
# Usage:
#   bash provision-scaleway.sh --full              # Create → Rescue → Install → Boot → Validate
#   bash provision-scaleway.sh --create            # Just provision the server
#   bash provision-scaleway.sh --rescue            # Reboot into rescue mode
#   bash provision-scaleway.sh --install           # Upload scripts and run XCP-ng install
#   bash provision-scaleway.sh --boot              # Reboot to normal mode
#   bash provision-scaleway.sh --validate          # Wait for XCP-ng SSH and verify
#   bash provision-scaleway.sh --teardown          # Delete server
#
# Environment variables:
#   ZONE            Scaleway zone (default: fr-par-2)
#   SERVER_TYPE     Server offer (default: EM-A116X-SSD)
#   SERVER_NAME     Server name (default: xcp-ng-poc)
#   SSH_KEY_PATH    Path to SSH private key (default: ~/.ssh/ai-workstation)
#   REAL_DNS        DNS server for XCP-ng (default: 51.159.47.28)
#   MAX_HARDWARE_RETRIES  Max server allocations before giving up (default: 5)
#
# Prerequisites:
#   - scw CLI configured (`scw init`)
#   - SSH key at ~/.ssh/ai-workstation (or set SSH_KEY_PATH)
#   - sshpass installed (for rescue password auth)
#
# Lessons learned:
#   - "Custom install" option doesn't register SSH keys — must inject manually
#   - Rescue mode boots Ubuntu into RAM — disks are clean, no RAID
#   - Server creation with "no OS" is fast (~3-5 min vs 20 min with Ubuntu)
#   - boot-type is set on REBOOT, not on CREATE or UPDATE
#   - "reboot boot-type=rescue" does NOT work on no-OS servers — must stop then start
#   - Rescue user is "em-XXXXX" (not root) — sudo requires password
#   - Scaleway sudoers has duplicate %admin rule AFTER #includedir — must append NOPASSWD to EOF
#   - Gateway is .1 of the /24 subnet
#   - Hardware lottery: EM-A116X-SSD randomly gives Dell (works) or HPE (incompatible)
#   - HPE servers in this offer are unreliable with XCP-ng — reject all, retry for Dell

ZONE="${ZONE:-fr-par-2}"
SERVER_TYPE="${SERVER_TYPE:-EM-A116X-SSD}"
SERVER_NAME="${SERVER_NAME:-xcp-ng-poc}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/ai-workstation}"
REAL_DNS="${REAL_DNS:-51.159.47.28}"
MAX_HARDWARE_RETRIES="${MAX_HARDWARE_RETRIES:-5}"
if ! [[ "$MAX_HARDWARE_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_HARDWARE_RETRIES must be a positive integer (got: '$MAX_HARDWARE_RETRIES')" >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
STATE_FILE="${SCRIPT_DIR}/.provision-state"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- Timing instrumentation ---
declare -A _PHASE_START
_SCRIPT_START=$(date +%s)
TIMING_LOG=$(mktemp /tmp/provision-scaleway-timing.XXXXXX)
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
    local total_elapsed=$(( $(date +%s) - _SCRIPT_START ))
    local total_min=$((total_elapsed / 60))
    local total_sec=$((total_elapsed % 60))
    echo ""
    echo "=============================================="
    echo "  PROVISIONING TIMING SUMMARY"
    echo "=============================================="
    if [ -f "$TIMING_LOG" ]; then
        while IFS='|' read -r name elapsed; do
            printf "  %-30s %3dm %02ds\n" "$name" "$((elapsed/60))" "$((elapsed%60))"
        done < "$TIMING_LOG"
        echo "----------------------------------------------"
    fi
    printf "  %-30s %3dm %02ds\n" "TOTAL" "$total_min" "$total_sec"
    echo "=============================================="
}

# --- State management ---

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        log "Loaded state: SERVER_ID=${SERVER_ID:-}, SERVER_IP=${SERVER_IP:-}"
    else
        log "No state file found. Run --create first or set SERVER_ID/SERVER_IP."
    fi
}

save_state() {
    cat > "$STATE_FILE" << EOF
SERVER_ID='${SERVER_ID//\'/\'\\\'\'}'
SERVER_IP='${SERVER_IP//\'/\'\\\'\'}'
RESCUE_USER='${RESCUE_USER:-}'
RESCUE_PASS='${RESCUE_PASS:-}'
EOF
    chmod 600 "$STATE_FILE"
    log "State saved to $STATE_FILE"
}

# --- Hardware compatibility check ---
# Scaleway EM-A116X-SSD randomly allocates Dell or HPE hardware.
# HPE ProLiant DL320e Gen8 v2 has a Smart Array B120i controller that
# fails with "Unaligned write command" under plain AHCI — incompatible
# with XCP-ng. Dell PowerEdge R220 works fine.
#
# Two-level detection:
#   1. Early: BMC info via Scaleway API (before boot, ~instant)
#   2. Rescue: DMI/lspci via SSH (after rescue boot, definitive)
#
# Returns 0 = compatible, 1 = incompatible

# Level 1: Check via Scaleway BMC API (pre-boot, best-effort)
# Requires: KVM option enabled + BMC session started.
# BMC session needs our public IP — we detect it automatically.
check_hardware_via_bmc() {
    log "--- Hardware check via BMC API ---"

    # Step 1: Start BMC session (requires our public IP for authorization)
    local my_ip
    my_ip=$(curl -s -m 5 https://ifconfig.me 2>/dev/null || curl -s -m 5 https://api.ipify.org 2>/dev/null || echo "")
    if [ -z "$my_ip" ]; then
        log "WARNING: Could not detect public IP — skipping BMC check"
        return 0
    fi

    # Start BMC access (idempotent if already started)
    scw baremetal bmc start server-id="$SERVER_ID" ip="$my_ip" zone="$ZONE" >/dev/null 2>&1 || true

    # Step 2: Get BMC credentials
    local bmc_json
    bmc_json=$(scw baremetal bmc get server-id="$SERVER_ID" zone="$ZONE" -o json 2>/dev/null) || {
        log "WARNING: Could not query BMC API — skipping early check"
        return 0  # unknown = proceed
    }

    local bmc_url bmc_user bmc_pass
    read -r bmc_url bmc_user bmc_pass < <(echo "$bmc_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('url',''), d.get('login',''), d.get('password',''))
" 2>/dev/null) || true

    if [ -z "$bmc_url" ] || [ -z "$bmc_user" ] || [ -z "$bmc_pass" ]; then
        log "WARNING: BMC credentials incomplete — skipping early check"
        return 0
    fi

    # Extract hostname/IP from BMC URL
    local bmc_host
    bmc_host=$(echo "$bmc_url" | sed -E 's|https?://||; s|/.*||; s|:.*||')
    log "BMC host: $bmc_host (user: $bmc_user)"

    # Step 3: Fastest detection — inspect the BMC TLS certificate.
    # Dell iDRAC certs contain "Dell Inc." in the subject/issuer.
    # HPE iLO certs contain "Hewlett" or "HP" in the subject/issuer.
    # No authentication needed — openssl s_client extracts only the cert subject,
    # avoiding false matches from HTTP response content.
    local cert_subject
    cert_subject=$(openssl s_client -connect "${bmc_host}:443" -servername "${bmc_host}" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "")
    log "BMC TLS certificate: $cert_subject"

    if echo "$cert_subject" | grep -qi "Dell"; then
        log "Dell hardware detected via BMC certificate (iDRAC)"
        return 0  # Dell = compatible
    elif echo "$cert_subject" | grep -qi "Hewlett\|HP\|iLO"; then
        log "HPE hardware detected via BMC certificate (iLO)"
        log "INCOMPATIBLE: HPE servers in this offer use B120i controller"
        return 1  # HPE = incompatible (B120i)
    fi

    # Fallback: Try Redfish API with authentication
    # NOTE: -k (insecure) is required because Scaleway BMC endpoints use
    # self-signed certificates. BMC credentials are short-lived and
    # scoped to this session.
    local model=""

    # Dell iDRAC Redfish path
    if [ -z "$model" ]; then
        model=$(curl -sk -m 10 -u "${bmc_user}:${bmc_pass}" \
            "https://${bmc_host}/redfish/v1/Systems/System.Embedded.1" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('Model',''))" 2>/dev/null || echo "")
    fi

    # HPE iLO Redfish path
    if [ -z "$model" ]; then
        model=$(curl -sk -m 10 -u "${bmc_user}:${bmc_pass}" \
            "https://${bmc_host}/redfish/v1/Systems/1" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('Model',''))" 2>/dev/null || echo "")
    fi

    # Dell racadm via SSH
    # NOTE: StrictHostKeyChecking=no is required because BMC SSH host keys
    # are unique per allocation and unknown ahead of time.
    if [ -z "$model" ]; then
        model=$(sshpass -p "$bmc_pass" ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no -o ConnectTimeout=5 \
            "$bmc_user@$bmc_host" "racadm getsysinfo -s" 2>/dev/null | \
            grep -i "System Model" | sed 's/.*= *//' || echo "")
    fi

    if [ -z "$model" ]; then
        log "BMC reachable but model detection failed — will check in rescue mode"
        return 0
    fi

    log "BMC reports hardware: $model"

    # Check for known-incompatible models
    case "$model" in
        *DL320e*|*DL360e*|*DL380e*)
            # HPE Gen8 "e" models typically use B120i
            log "INCOMPATIBLE: HPE $model likely has B120i controller"
            return 1
            ;;
        *PowerEdge*|*Dell*)
            log "Dell $model — known compatible"
            return 0
            ;;
        *)
            log "Model '$model' not in known-good/bad list — will verify in rescue"
            return 0
            ;;
    esac
}

# Level 2: Check via rescue mode SSH (post-boot, definitive)
check_hardware_via_rescue() {
    log "--- Hardware check via rescue SSH ---"

    # DMI files are world-readable — no sudo needed (avoids TTY/password issues)
    local vendor
    vendor=$(ssh_key "cat /sys/class/dmi/id/sys_vendor 2>/dev/null" 2>/dev/null || echo "unknown")
    local product
    product=$(ssh_key "cat /sys/class/dmi/id/product_name 2>/dev/null" 2>/dev/null || echo "unknown")
    log "Hardware: $vendor $product"

    # Check for HPE B120i — software RAID controller with broken AHCI writes
    local has_b120i
    has_b120i=$(ssh_key "lspci 2>/dev/null | grep -ci 'B120i\|Smart Array.*B1'" 2>/dev/null | tr -d '[:space:]' || echo "0")
    [ -z "$has_b120i" ] && has_b120i=0

    if [ "$has_b120i" -gt 0 ]; then
        log "INCOMPATIBLE: HPE Smart Array B120i detected"
        log "  This controller rejects writes under plain AHCI (XCP-ng kernel)."
        log "  dmesg would show: 'Sense Key: Illegal Request — Unaligned write command'"
        return 1
    fi

    # Reject ALL HPE hardware — every HPE server in this offer has had issues.
    # B120i is the known failure mode, but other HPE storage controllers may
    # also be incompatible with XCP-ng's kernel drivers.
    case "$vendor" in
        *HP*|*Hewlett*)
            log "INCOMPATIBLE: HPE hardware detected ($product)"
            log "  All HPE servers in the EM-A116X-SSD offer have proven unreliable with XCP-ng."
            return 1
            ;;
        *Dell*)
            log "Dell hardware ($product) — known compatible"
            ;;
        *)
            log "Unknown vendor ($vendor $product) — proceeding with caution"
            ;;
    esac

    return 0
}

# --- SSH helpers ---

ssh_rescue() {
    if [ -n "$RESCUE_PASS" ]; then
        sshpass -p "$RESCUE_PASS" ssh \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no \
            -o ConnectTimeout=10 \
            "$RESCUE_USER@$SERVER_IP" "$@"
    else
        ssh -i "$SSH_KEY_PATH" \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "$RESCUE_USER@$SERVER_IP" "$@"
    fi
}

ssh_key() {
    ssh -i "$SSH_KEY_PATH" \
        -o IdentitiesOnly=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "$RESCUE_USER@$SERVER_IP" "$@"
}

scp_key() {
    scp -i "$SSH_KEY_PATH" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "$@"
}

ssh_xcpng() {
    ssh -i "$SSH_KEY_PATH" \
        -o IdentitiesOnly=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "root@$SERVER_IP" "$@"
}

# =========================================================================
# STEP 1: CREATE
# =========================================================================
do_create() {
    phase_start "Server creation"
    log "=== Step 1: Create server ==="
    CUSTOM_OS_ID=$(scw baremetal os list zone="$ZONE" -o json | python3 -c "
import sys,json
for os in json.load(sys.stdin):
    if 'Custom' in os.get('name',''):
        print(os['id']); break
")
    log "Custom install OS ID: $CUSTOM_OS_ID"

    # Look up SSH key ID for rescue key-based auth (fr-par-1 needs it at creation)
    SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" 2>/dev/null | awk '{print $2}')
    SCW_SSH_KEY_ID=$(scw iam ssh-key list -o json 2>/dev/null | python3 -c "
import sys,json
fp=sys.argv[1]
for k in json.load(sys.stdin):
    if fp and k.get('fingerprint','') == fp:
        print(k['id']); break
" "$SSH_KEY_FINGERPRINT" 2>/dev/null)

    CREATE_CMD=(scw baremetal server create "name=$SERVER_NAME" "zone=$ZONE" "type=$SERVER_TYPE" "install.os-id=$CUSTOM_OS_ID" "tags.0=RemoteAccess")
    if [ -n "$SCW_SSH_KEY_ID" ]; then
        log "Attaching SSH key: $SCW_SSH_KEY_ID"
        CREATE_CMD+=("install.ssh-key-ids.0=$SCW_SSH_KEY_ID")
    fi
    OUTPUT=$("${CREATE_CMD[@]}" -o json 2>&1)

    SERVER_ID=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    log "Server created: $SERVER_ID"
    log "Waiting for delivery (may take 5-10 minutes)..."

    scw baremetal server wait "$SERVER_ID" zone="$ZONE" 2>&1 | tail -1
    SERVER_IP=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json | \
        python3 -c "import sys,json; [print(ip['address']) for ip in json.load(sys.stdin)['ips'] if ip['version']=='IPv4']")
    log "Server ready: $SERVER_IP"

    # Save state immediately after creation so we can resume if KVM enablement
    # or later steps fail. Without this, a failure in KVM setup would leave no
    # state file despite the server existing (and costing money).
    RESCUE_USER="root"
    RESCUE_PASS=""
    save_state

    # Enable KVM (Remote Access) for BMC/iDRAC console access
    KVM_OPTION_ID="931df052-d713-4674-8b58-96a63244c8e2"
    HAS_KVM=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json | python3 -c "
import sys,json
opts=json.load(sys.stdin).get('options',[])
print('yes' if any(o.get('id')=='$KVM_OPTION_ID' for o in opts) else 'no')
" 2>/dev/null)
    if [ "$HAS_KVM" = "no" ]; then
        log "Enabling KVM (Remote Access)..."
        scw baremetal options add server-id="$SERVER_ID" option-id="$KVM_OPTION_ID" zone="$ZONE" >/dev/null 2>&1
        log "KVM enabled"
    else
        log "KVM already enabled"
    fi

    # Early hardware compatibility check via BMC (before booting rescue)
    if ! check_hardware_via_bmc; then
        log "Server hardware is incompatible with XCP-ng."
        log "HARDWARE_INCOMPATIBLE flag set — caller should teardown and retry."
        HARDWARE_INCOMPATIBLE=true
        phase_end "Server creation"
        return 0  # don't exit — let caller handle retry
    fi
    HARDWARE_INCOMPATIBLE=false
    phase_end "Server creation"
}

# =========================================================================
# STEP 2: RESCUE
# =========================================================================
do_rescue() {
    load_state
    phase_start "Rescue mode"
    log "=== Step 2: Boot into rescue mode ==="

    # Check current status — use stop+start instead of reboot
    # Discovered: 'reboot boot-type=rescue' doesn't work on no-OS servers
    STATUS=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    BOOT_TYPE=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('boot_type',''))" 2>/dev/null || true)

    if [ "$BOOT_TYPE" = "rescue" ] && [ "$STATUS" = "ready" ]; then
        log "Already in rescue mode"
    else
        log "Stopping server..."
        scw baremetal server stop "$SERVER_ID" zone="$ZONE" >/dev/null 2>&1 || true
        STOPPED=false
        for i in $(seq 1 30); do
            S=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null | \
                python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
            if [ "$S" = "stopped" ]; then
                STOPPED=true
                break
            fi
            printf "\r  Waiting for stop... (%d/30, status: %s)" "$i" "$S"
            sleep 10
        done
        echo ""
        if [ "$STOPPED" = "false" ]; then
            log "ERROR: Server did not reach stopped state within timeout"
            exit 1
        fi

        log "Starting in rescue mode..."
        scw baremetal server start "$SERVER_ID" boot-type=rescue zone="$ZONE" >/dev/null 2>&1
        log "Waiting for rescue mode..."
        scw baremetal server wait "$SERVER_ID" zone="$ZONE" 2>&1 | tail -1
    fi

    # Fetch rescue credentials from API
    log "Fetching rescue credentials..."
    for i in $(seq 1 5); do
        SERVER_INFO=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null) || true
        RESCUE_USER=$(echo "$SERVER_INFO" | python3 -c "
import sys,json
rs=json.load(sys.stdin).get('rescue_server',{})
print(rs.get('user',''))
" 2>/dev/null)
        RESCUE_PASS=$(echo "$SERVER_INFO" | python3 -c "
import sys,json
rs=json.load(sys.stdin).get('rescue_server',{})
print(rs.get('password',''))
" 2>/dev/null)
        if [ -n "$RESCUE_USER" ] && [ -n "$RESCUE_PASS" ]; then
            break
        fi
        sleep 5
    done

    if [ -z "$RESCUE_USER" ] || [ -z "$RESCUE_PASS" ]; then
        # fr-par-1 style: no password-based rescue, try key-based auth with 'rescue' user
        log "No password rescue credentials — trying key-based auth..."
        RESCUE_USER="rescue"
        RESCUE_PASS=""
        if ! ssh_rescue "echo ok" &>/dev/null; then
            log "ERROR: Could not retrieve rescue credentials and key-based auth failed"
            exit 1
        fi
        log "Key-based rescue auth works with user: $RESCUE_USER"
    else
        log "Rescue user: $RESCUE_USER"
        log "Rescue credentials received (not logged for security)"
    fi
    save_state

    # Wait for SSH
    log "Waiting for rescue SSH (may take 3-5 minutes)..."
    SSH_OK=false
    for i in $(seq 1 30); do
        if ssh_rescue "echo ok" &>/dev/null; then
            SSH_OK=true
            echo ""
            log "Rescue SSH ready!"
            break
        fi
        printf "\r  Attempt %d/30..." "$i"
        sleep 10
    done
    if [ "$SSH_OK" = "false" ]; then
        log "ERROR: Rescue SSH never came up after 5 minutes"
        exit 1
    fi

    # Inject SSH key for key-based auth
    log "Injecting SSH key..."
    PUBKEY=$(cat "${SSH_KEY_PATH}.pub")
    printf '%s\n' "$PUBKEY" | ssh_rescue "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
    log "SSH key injected"

    # Setup passwordless sudo
    # GOTCHA: Scaleway rescue sudoers has duplicate "%admin ALL=(ALL) ALL" AFTER #includedir.
    # Last matching rule wins, so /etc/sudoers.d/ rules get overridden.
    # Fix: append NOPASSWD to the END of /etc/sudoers itself.
    log "Setting up passwordless sudo..."
    if [ -z "$RESCUE_PASS" ]; then
        # Key-based rescue (fr-par-1 style) — sudo already works without password
        SUDO_RESULT=$(ssh_rescue \
            "sudo bash -c 'grep -qF \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" /etc/sudoers || echo \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers && echo SUDO_OK'" 2>/dev/null)
    else
        # Password-based rescue (fr-par-2 style) — pipe password to sudo -S
        SUDO_RESULT=$(printf '%s\n' "$RESCUE_PASS" | ssh_rescue \
            "sudo -S bash -c 'grep -qF \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" /etc/sudoers || echo \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers && echo SUDO_OK'" 2>/dev/null)
    fi

    if echo "$SUDO_RESULT" | grep -q "SUDO_OK"; then
        log "Passwordless sudo configured"
    else
        log "WARNING: sudo setup via pipe failed, trying with TTY..."
        if [ -n "$RESCUE_PASS" ]; then
            printf '%s\n' "$RESCUE_PASS" | sshpass -p "$RESCUE_PASS" ssh -tt \
                -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
                "$RESCUE_USER@$SERVER_IP" \
                "sudo -S bash -c 'grep -qF \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" /etc/sudoers || echo \"$RESCUE_USER ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers'" 2>/dev/null
        fi
    fi

    # Verify
    if ssh_key "sudo whoami" 2>/dev/null | grep -q "root"; then
        log "Verified: sudo works without password"
    else
        log "ERROR: Passwordless sudo setup failed"
        log "  Rescue user: $RESCUE_USER"
        log "  Try manually: sshpass -p '<pass>' ssh $RESCUE_USER@$SERVER_IP"
        exit 1
    fi

    # Definitive hardware check via rescue SSH (catches what BMC missed)
    if ! check_hardware_via_rescue; then
        log "Server hardware is incompatible with XCP-ng (confirmed in rescue)."
        log "HARDWARE_INCOMPATIBLE flag set — caller should teardown and retry."
        HARDWARE_INCOMPATIBLE=true
        phase_end "Rescue mode"
        return 0
    fi
    HARDWARE_INCOMPATIBLE=false
    phase_end "Rescue mode"
}

# =========================================================================
# STEP 3: INSTALL
# =========================================================================
do_install() {
    load_state
    phase_start "XCP-ng install"
    log "=== Step 3: Install XCP-ng via QEMU ==="

    # Upload scripts
    WORK="/home/${RESCUE_USER}/xcp-ng"
    log "Uploading scripts to $WORK..."
    ssh_key "mkdir -p $WORK"
    for f in install-via-qemu.sh build-iso.sh answerfile.xml; do
        if [ -f "$SCRIPT_DIR/$f" ]; then
            scp_key "$SCRIPT_DIR/$f" "$RESCUE_USER@$SERVER_IP:$WORK/"
            log "  Uploaded: $f"
        else
            log "ERROR: $f not found in $SCRIPT_DIR"
            exit 1
        fi
    done

    # Upload SSH public key for injection into XCP-ng
    if [ -f "${SSH_KEY_PATH}.pub" ]; then
        scp_key "${SSH_KEY_PATH}.pub" "$RESCUE_USER@$SERVER_IP:$WORK/authorized_keys.pub"
        log "  Uploaded: SSH public key for XCP-ng root access"
    else
        log "  WARNING: No SSH public key found at ${SSH_KEY_PATH}.pub — XCP-ng will only accept password auth"
    fi

    # Show disk layout for logging
    log "Disk layout on server:"
    ssh_key "lsblk -o NAME,SIZE,TYPE,FSTYPE" 2>/dev/null || true

    # Compute network config
    GATEWAY=$(echo "$SERVER_IP" | sed 's/\.[0-9]*$/.1/')
    log "Network config: IP=$SERVER_IP GW=$GATEWAY DNS=$REAL_DNS"

    # Run installation
    log "Starting QEMU-based installation (15-30 minutes)..."
    log "========================================================="
    ssh_key "
        export REAL_IP=$SERVER_IP
        export REAL_GATEWAY=$GATEWAY
        export REAL_DNS=$REAL_DNS
        export TARGET_DISK=/dev/sda
        cd $WORK
        chmod +x install-via-qemu.sh build-iso.sh
        sudo -E bash install-via-qemu.sh
    " 2>&1 | while IFS= read -r line; do
        echo "$line"
    done
    log "========================================================="
    log "Installation script completed"
    phase_end "XCP-ng install"
}

# =========================================================================
# STEP 4: BOOT
# =========================================================================
do_boot() {
    load_state
    phase_start "Bare metal boot"
    log "=== Step 4: Boot to bare metal (XCP-ng from disk) ==="
    # CRITICAL: Use stop+start, NOT reboot!
    # 'reboot boot-type=normal' doesn't properly reconfigure PXE on no-OS servers.
    log "Stopping server..."
    scw baremetal server stop "$SERVER_ID" zone="$ZONE" >/dev/null 2>&1 || true
    log "Waiting for server to stop..."
    STOPPED=false
    for i in $(seq 1 30); do
        S=$(scw baremetal server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
        if [ "$S" = "stopped" ]; then
            STOPPED=true
            break
        fi
        printf "\r  Waiting... (%d/30, status: %s)" "$i" "$S"
        sleep 10
    done
    echo ""
    if [ "$STOPPED" = "false" ]; then
        log "ERROR: Server did not reach stopped state within timeout"
        exit 1
    fi

    log "Starting in normal boot mode..."
    scw baremetal server start "$SERVER_ID" boot-type=normal zone="$ZONE" >/dev/null 2>&1
    log "Waiting for server to be ready..."
    scw baremetal server wait "$SERVER_ID" zone="$ZONE" 2>&1 | tail -1
    log "Server started in normal mode"
    phase_end "Bare metal boot"
}

# =========================================================================
# STEP 5: VALIDATE
# =========================================================================
do_validate() {
    load_state
    phase_start "Validation"
    log "=== Step 5: Validate XCP-ng is alive ==="
    log "Waiting for XCP-ng SSH (may take 3-5 minutes for first boot)..."

    SSH_OK=false
    for i in $(seq 1 30); do
        if ssh_xcpng "echo ok" &>/dev/null; then
            SSH_OK=true
            echo ""
            log "XCP-ng SSH is up!"
            break
        fi
        printf "\r  Attempt %d/30..." "$i"
        sleep 10
    done

    if [ "$SSH_OK" = "false" ]; then
        log "ERROR: XCP-ng SSH did not come up after 5 minutes"
        log "Possible causes:"
        log "  - Networking: OVS config may be wrong (check via BMC/KVM)"
        log "  - Boot: Kernel panic or GRUB failure (check via BMC/KVM)"
        log "  - Dell: GPT→MBR conversion may have failed"
        log ""
        log "Debug via BMC:"
        log "  scw baremetal bmc get server-id=$SERVER_ID zone=$ZONE -o json"
        exit 1
    fi

    # Run validation checks
    log ""
    log "--- XCP-ng validation checks ---"

    log "1. Host info:"
    ssh_xcpng "xe host-list params=name-label,software-version" 2>/dev/null || log "  WARNING: xe host-list failed"

    log ""
    log "2. Network interfaces:"
    ssh_xcpng "ip addr show | grep -E 'inet |state'" 2>/dev/null || log "  WARNING: ip addr failed"

    log ""
    log "3. Storage repositories:"
    ssh_xcpng "xe sr-list params=name-label,type,physical-size" 2>/dev/null || log "  WARNING: xe sr-list failed"

    log ""
    log "4. XAPI status:"
    ssh_xcpng "systemctl is-active xapi" 2>/dev/null || log "  WARNING: xapi not active"

    log ""
    log "5. Management interface:"
    ssh_xcpng "cat /etc/xensource/network.conf && xe pif-list params=device,IP,management" 2>/dev/null || log "  WARNING: PIF check failed"

    log ""
    log "========================================================="
    log "XCP-ng is running on bare metal at $SERVER_IP"
    log "SSH:  ssh -i $SSH_KEY_PATH root@$SERVER_IP"
    log "XO:   Connect Xen Orchestra to https://$SERVER_IP"
    log "========================================================="
    phase_end "Validation"
}

# =========================================================================
# STEP 6: TEARDOWN
# =========================================================================
do_teardown() {
    load_state
    log "=== Teardown: Deleting server ==="
    scw baremetal server delete "$SERVER_ID" zone="$ZONE" 2>&1
    log "Server deleted: $SERVER_ID"
    rm -f "$STATE_FILE"
}

# =========================================================================
# MAIN
# =========================================================================
do_preflight() {
    log "=== Preflight checks ==="
    local ok=true

    # Check required CLI tools
    for cmd in scw ssh sshpass jq curl python3 openssl; do
        if command -v "$cmd" &>/dev/null; then
            log "  $cmd: OK ($(command -v "$cmd"))"
        else
            log "  $cmd: MISSING — install with: sudo apt-get install $cmd"
            ok=false
        fi
    done

    # Check SSH key
    if [ -f "$SSH_KEY_PATH" ]; then
        log "  SSH key: OK ($SSH_KEY_PATH)"
    else
        log "  SSH key: MISSING ($SSH_KEY_PATH)"
        log "    Generate with: ssh-keygen -t ed25519 -f $SSH_KEY_PATH"
        ok=false
    fi
    if [ -f "${SSH_KEY_PATH}.pub" ]; then
        log "  SSH public key: OK (${SSH_KEY_PATH}.pub)"
    else
        log "  SSH public key: MISSING (${SSH_KEY_PATH}.pub)"
        ok=false
    fi

    # Check Scaleway CLI auth
    if scw account ssh-key list -o json &>/dev/null; then
        log "  Scaleway auth: OK"
    else
        log "  Scaleway auth: FAILED — run: scw init"
        ok=false
    fi

    # Check zone availability
    if scw baremetal offer list zone="$ZONE" -o json 2>/dev/null | python3 -c "
import sys,json
offers=json.load(sys.stdin)
found=[o for o in offers if sys.argv[1] in o.get('name','')]
sys.exit(0 if found else 1)
" "$SERVER_TYPE" 2>/dev/null; then
        log "  Server type $SERVER_TYPE in $ZONE: OK"
    else
        log "  Server type $SERVER_TYPE in $ZONE: NOT FOUND or zone unavailable"
        ok=false
    fi

    # Check companion scripts
    for f in install-via-qemu.sh build-iso.sh answerfile.xml xcp-ng-version.env; do
        if [ -f "$SCRIPT_DIR/$f" ]; then
            log "  $f: OK"
        else
            log "  $f: MISSING in $SCRIPT_DIR"
            ok=false
        fi
    done

    if [ "$ok" = "true" ]; then
        log ""
        log "All preflight checks passed. Ready to provision."
    else
        log ""
        log "ERROR: Some preflight checks failed. Fix the issues above before running --full."
        exit 1
    fi
}

case "${1:-}" in
    --preflight) do_preflight ;;
    --create)   do_create ;;
    --rescue)   do_rescue ;;
    --install)  do_install ;;
    --boot)     do_boot ;;
    --validate) do_validate ;;
    --teardown) do_teardown ;;
    --full)
        HARDWARE_INCOMPATIBLE=false
        for attempt in $(seq 1 "$MAX_HARDWARE_RETRIES"); do
            log "=== Hardware attempt $attempt/$MAX_HARDWARE_RETRIES ==="
            do_create

            if [ "$HARDWARE_INCOMPATIBLE" = "true" ]; then
                log "Incompatible hardware on attempt $attempt — tearing down and retrying..."
                do_teardown
                # Wait for server deletion to complete before re-allocating
                log "Waiting for server deletion to complete..."
                for i in $(seq 1 30); do
                    if ! scw baremetal server get "$SERVER_ID" zone="$ZONE" >/dev/null 2>&1; then
                        log "Server deleted after ${i}0s"
                        break
                    fi
                    sleep 10
                done
                continue
            fi

            do_rescue

            if [ "$HARDWARE_INCOMPATIBLE" = "true" ]; then
                log "Incompatible hardware confirmed in rescue on attempt $attempt — tearing down..."
                do_teardown
                # Wait for server deletion to complete before re-allocating
                log "Waiting for server deletion to complete..."
                for i in $(seq 1 30); do
                    if ! scw baremetal server get "$SERVER_ID" zone="$ZONE" >/dev/null 2>&1; then
                        log "Server deleted after ${i}0s"
                        break
                    fi
                    sleep 10
                done
                continue
            fi

            # Hardware OK — proceed with install
            break
        done

        if [ "$HARDWARE_INCOMPATIBLE" = "true" ]; then
            log "ERROR: Could not get compatible hardware after $MAX_HARDWARE_RETRIES attempts"
            log "  All allocations were HPE with B120i controller."
            log "  Try again later or contact Scaleway support."
            exit 1
        fi

        do_install
        do_boot
        do_validate
        print_timing_summary
        ;;
    *)
        echo "Usage: $0 [--preflight|--create|--rescue|--install|--boot|--validate|--teardown|--full]"
        echo ""
        echo "  --preflight Check prerequisites (tools, SSH key, Scaleway auth, zone)"
        echo "  --create    Provision server with 'Custom install' (no OS)"
        echo "  --rescue    Boot into rescue mode, inject SSH key, setup sudo"
        echo "  --install   Upload scripts and run XCP-ng installation"
        echo "  --boot      Reboot to normal mode (XCP-ng from disk)"
        echo "  --validate  Wait for XCP-ng SSH and run health checks"
        echo "  --teardown  Delete server"
        echo "  --full      Run all steps: create → rescue → install → boot → validate"
        echo ""
        echo "Each step saves state to .provision-state so you can resume after failure."
        echo "Example:"
        echo "  $0 --preflight                 # Verify everything is ready"
        echo "  $0 --full                      # Full unattended run"
        echo "  $0 --boot && $0 --validate     # Resume from a failed boot"
        exit 1
        ;;
esac
