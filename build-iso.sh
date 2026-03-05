#!/bin/bash
set -euo pipefail

# Build a custom XCP-ng netinstall ISO with answer file baked in
#
# Can run inside Docker or natively on a Debian-based system.
#
# Usage (Docker):
#   docker run --rm -v /tmp/xcp-ng-build:/work debian:trixie-slim bash -c \
#     "apt-get update -qq && apt-get install -y -qq curl genisoimage syslinux-utils libarchive-tools bzip2 cpio openssl && bash /work/build-iso.sh"
#
# Usage (native, e.g. Scaleway rescue mode):
#   export WORK=/home/ubuntu/xcp-ng   # or wherever your files are
#   apt-get install -y curl genisoimage syslinux-utils libarchive-tools bzip2 cpio
#   bash build-iso.sh
#
# Requirements:
#   - curl, genisoimage, isohybrid (syslinux-utils), bsdtar (libarchive-tools), bzip2, cpio
#   - $WORK/answerfile.xml must exist
#
# Lessons learned (2026-02-28):
#   - XCP-ng netinstall ISO (~164 MB) has NO packages — source type="url" is mandatory
#   - isolinux.cfg uses UPPERCASE keywords (APPEND, KERNEL) — case-sensitive matching fails
#   - mboot.c32 APPEND format: xen.gz ... --- vmlinuz ... --- /install.img
#   - The "--- /install.img" marker is the reliable anchor for parameter injection
#   - GRUB cfg uses "module2 /install.img" on separate line — same marker works inline
#   - ISO filenames include build date: xcp-ng-8.3.0-YYYYMMDD-netinstall.iso
#   - answerfile=file:///answerfile.xml means /answerfile.xml in the INITRAMFS, not the ISO
#   - Must inject answerfile INTO install.img (initramfs), not just the ISO root
#   - Linux supports concatenated cpio archives — append a small cpio to install.img

WORK="${WORK:-/work}"

# XCP-ng version — single source of truth
# Override via env: XCP_NG_VERSION=8.3.0-20250710 bash build-iso.sh
XCP_NG_VERSION="${XCP_NG_VERSION:-8.3.0-20250606}"
XCP_NG_MAJOR="${XCP_NG_VERSION%.*}"   # 8.3.0-20250606 → 8.3

# Strategy: Download BOTH ISOs
# - netinstall (~164MB) for QEMU boot (lighter, faster)
# - full ISO (~631MB) extracted on host, served via HTTP to installer
# The installer fetches packages from http://10.0.2.2:8099/ (QEMU SLIRP host)
# This avoids the Xen dom0 CD-ROM visibility problem
NETINSTALL_URL="https://mirrors.xcp-ng.org/isos/${XCP_NG_MAJOR}/xcp-ng-${XCP_NG_VERSION}-netinstall.iso"
NETINSTALL_SHA256_URL="https://mirrors.xcp-ng.org/isos/${XCP_NG_MAJOR}/SHA256SUMS"
FULL_ISO_URL="https://mirrors.xcp-ng.org/isos/${XCP_NG_MAJOR}/xcp-ng-${XCP_NG_VERSION}.iso"
NETINSTALL_FILE="${WORK}/xcp-ng-netinstall.iso"
FULL_ISO_FILE="${WORK}/xcp-ng-full.iso"
FULL_EXTRACT_DIR="${WORK}/full-iso-repo"
ISO_FILE="$NETINSTALL_FILE"
EXTRACT_DIR="${WORK}/iso-extract"
OUTPUT_ISO="${WORK}/xcp-ng-${XCP_NG_MAJOR}-unattended.iso"
ANSWERFILE="${WORK}/answerfile.xml"

# Validate answer file exists
if [ ! -f "$ANSWERFILE" ]; then
    echo "ERROR: $ANSWERFILE not found"
    exit 1
fi

# Substitute root password hash placeholder if present
# Set ROOT_PASSWORD_HASH env var, or a default "changeme" hash is generated
if grep -q '@@ROOT_PASSWORD_HASH@@' "$ANSWERFILE"; then
    if [ -z "${ROOT_PASSWORD_HASH:-}" ]; then
        echo "WARNING: ROOT_PASSWORD_HASH not set — generating hash for default password 'changeme'"
        ROOT_PASSWORD_HASH=$(openssl passwd -6 'changeme')
    fi
    sed -i "s|@@ROOT_PASSWORD_HASH@@|${ROOT_PASSWORD_HASH}|" "$ANSWERFILE"
    echo "Root password hash injected into answerfile"
fi

echo "=== Step 1a: Download XCP-ng netinstall ISO (for QEMU boot) ==="
if [ ! -f "$NETINSTALL_FILE" ]; then
    curl -L -o "$NETINSTALL_FILE" "$NETINSTALL_URL"
    FILE_SIZE=$(stat -c%s "$NETINSTALL_FILE" 2>/dev/null || stat -f%z "$NETINSTALL_FILE" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 100000000 ]; then
        echo "ERROR: Downloaded file is only $FILE_SIZE bytes — likely not a valid ISO"
        rm -f "$NETINSTALL_FILE"
        exit 1
    fi
    echo "Downloaded netinstall: $(ls -lh "$NETINSTALL_FILE" | awk '{print $5}')"
else
    echo "Already downloaded netinstall: $(ls -lh "$NETINSTALL_FILE" | awk '{print $5}')"
fi

# Verify checksum if SHA256SUMS is available
SHA256_FILE="${WORK}/SHA256SUMS"
if [ ! -f "$SHA256_FILE" ]; then
    curl -sL -o "$SHA256_FILE" "$NETINSTALL_SHA256_URL" 2>/dev/null || true
fi
if [ -f "$SHA256_FILE" ]; then
    NETINSTALL_BASENAME=$(basename "$NETINSTALL_URL")
    EXPECTED_SHA=$(grep "$NETINSTALL_BASENAME" "$SHA256_FILE" | awk '{print $1}')
    if [ -n "$EXPECTED_SHA" ]; then
        ACTUAL_SHA=$(sha256sum "$NETINSTALL_FILE" | awk '{print $1}')
        if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
            echo "Netinstall ISO checksum verified OK"
        else
            echo "ERROR: Netinstall ISO checksum mismatch!"
            echo "  Expected: $EXPECTED_SHA"
            echo "  Actual:   $ACTUAL_SHA"
            rm -f "$NETINSTALL_FILE"
            exit 1
        fi
    else
        echo "WARNING: No checksum found for $NETINSTALL_BASENAME in SHA256SUMS"
    fi
else
    echo "WARNING: SHA256SUMS not available — skipping checksum verification"
fi

echo ""
echo "=== Step 1b: Download full ISO and extract for HTTP repo ==="
if [ ! -f "$FULL_ISO_FILE" ]; then
    curl -L -o "$FULL_ISO_FILE" "$FULL_ISO_URL"
    FILE_SIZE=$(stat -c%s "$FULL_ISO_FILE" 2>/dev/null || stat -f%z "$FULL_ISO_FILE" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 500000000 ]; then
        echo "ERROR: Full ISO is only $FILE_SIZE bytes — likely not valid"
        rm -f "$FULL_ISO_FILE"
        exit 1
    fi
    echo "Downloaded full ISO: $(ls -lh "$FULL_ISO_FILE" | awk '{print $5}')"
else
    echo "Already downloaded full ISO: $(ls -lh "$FULL_ISO_FILE" | awk '{print $5}')"
fi

# Verify full ISO checksum
if [ -f "$SHA256_FILE" ]; then
    FULL_BASENAME=$(basename "$FULL_ISO_URL")
    EXPECTED_SHA=$(grep "$FULL_BASENAME" "$SHA256_FILE" | awk '{print $1}')
    if [ -n "$EXPECTED_SHA" ]; then
        ACTUAL_SHA=$(sha256sum "$FULL_ISO_FILE" | awk '{print $1}')
        if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
            echo "Full ISO checksum verified OK"
        else
            echo "ERROR: Full ISO checksum mismatch!"
            echo "  Expected: $EXPECTED_SHA"
            echo "  Actual:   $ACTUAL_SHA"
            rm -f "$FULL_ISO_FILE"
            exit 1
        fi
    else
        echo "WARNING: No checksum found for $FULL_BASENAME in SHA256SUMS"
    fi
fi

# Extract full ISO for HTTP serving (installer fetches packages from here)
if [ ! -d "$FULL_EXTRACT_DIR" ] || [ ! -f "$FULL_EXTRACT_DIR/.treeinfo" ]; then
    echo "Extracting full ISO for HTTP repository..."
    rm -rf "$FULL_EXTRACT_DIR"
    mkdir -p "$FULL_EXTRACT_DIR"
    cd "$FULL_EXTRACT_DIR"
    bsdtar xf "$FULL_ISO_FILE"
    echo "Full ISO extracted to $FULL_EXTRACT_DIR"
    echo "  .treeinfo: $(ls -la "$FULL_EXTRACT_DIR/.treeinfo" 2>/dev/null || echo 'MISSING!')"
    echo "  repodata: $(ls "$FULL_EXTRACT_DIR/repodata/" 2>/dev/null | wc -l) files"
else
    echo "Full ISO already extracted at $FULL_EXTRACT_DIR"
fi

echo ""
echo "=== Step 2: Extract ISO ==="
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
# Use bsdtar to extract (works without mount/loop/sudo)
cd "${EXTRACT_DIR}"
bsdtar xf "$ISO_FILE"
# bsdtar extracts ISO files as read-only — must fix permissions for modifications
chmod -R u+w "${EXTRACT_DIR}"
echo "Extracted to ${EXTRACT_DIR}"
ls -la "${EXTRACT_DIR}/"

echo ""
echo "=== Step 3: Inject answer file into initramfs (install.img) ==="
# The XCP-ng installer reads answerfile=file:///answerfile.xml from the RUNNING
# filesystem (the unpacked initramfs), NOT from the ISO. So we must inject the
# answerfile directly into install.img.
#
# install.img is a bzip2-compressed cpio archive. Linux supports concatenated
# cpio archives, so we append a small supplementary cpio containing our file.
INSTALL_IMG="${EXTRACT_DIR}/install.img"
if [ -f "$INSTALL_IMG" ]; then
    echo "Original install.img: $(ls -lh "$INSTALL_IMG" | awk '{print $5}')"
    # Create a temporary directory with the answerfile at the root
    CPIO_STAGING=$(mktemp -d)
    cp "$ANSWERFILE" "${CPIO_STAGING}/answerfile.xml"
    # Create a cpio archive and bzip2 compress it, then append to install.img
    (cd "$CPIO_STAGING" && echo "answerfile.xml" | cpio -o -H newc 2>/dev/null) | bzip2 >> "$INSTALL_IMG"
    rm -rf "$CPIO_STAGING"
    echo "Answerfile injected into install.img"
    echo "Modified install.img: $(ls -lh "$INSTALL_IMG" | awk '{print $5}')"
else
    echo "WARNING: install.img not found at $INSTALL_IMG"
fi
# Also keep a copy on the ISO root for reference
cp "$ANSWERFILE" "${EXTRACT_DIR}/answerfile.xml"
echo "Answer file also added to ISO root"

echo ""
echo "=== Step 4: Modify boot configs ==="

# The XCP-ng boot configs use mboot.c32 (Xen multiboot) with this format:
#   KERNEL mboot.c32
#   APPEND /boot/xen.gz ... --- /boot/vmlinuz ... console=tty0 --- /install.img
#
# The answerfile parameters go on the vmlinuz module line (between the two ---).
# We use " --- /install.img" as anchor — it's unique, case-safe, and works for
# both isolinux.cfg (BIOS) and grub.cfg (UEFI).

# CRITICAL: network_device=eth0 forces the init script to DHCP-configure dom0
# networking BEFORE the installer runs. Without this, answerfile=file:// URLs
# cause init_network=False, so dom0 networking is never configured, and
# source type="url" in the answerfile silently fails with "No main repository found".
ANSWERFILE_PARAMS="answerfile=file:///answerfile.xml install network_device=eth0"

# BIOS boot: isolinux.cfg
ISOLINUX_CFG="${EXTRACT_DIR}/boot/isolinux/isolinux.cfg"
if [ -f "$ISOLINUX_CFG" ]; then
    echo "--- Original isolinux.cfg (APPEND lines) ---"
    grep -ni "APPEND\|append" "$ISOLINUX_CFG" || true
    # Insert answerfile params before " --- /install.img"
    sed -i "s| --- /install\.img| ${ANSWERFILE_PARAMS} --- /install.img|g" "$ISOLINUX_CFG"
    echo "--- Modified isolinux.cfg (APPEND lines) ---"
    grep -ni "APPEND\|append" "$ISOLINUX_CFG" || true
else
    echo "WARNING: No isolinux.cfg found at $ISOLINUX_CFG"
fi

# UEFI boot: grub.cfg
# XCP-ng grub.cfg has vmlinuz params on "module2" lines, and /install.img on a
# separate "module2" line. The inline " --- /install.img" pattern doesn't exist
# in GRUB cfg. Instead, we append params to vmlinuz module2 lines directly.
GRUB_CFG=$(find "${EXTRACT_DIR}" -name "grub.cfg" -path "*/EFI/*" 2>/dev/null | head -1)
if [ -n "$GRUB_CFG" ]; then
    echo ""
    echo "--- Original grub.cfg (module2 lines) ---"
    grep -n "module2" "$GRUB_CFG" | head -12 || true
    # Append answerfile params to vmlinuz module2 lines (not install.img lines)
    sed -i "/module2.*vmlinuz/s|$| ${ANSWERFILE_PARAMS}|" "$GRUB_CFG"
    echo "--- Modified grub.cfg (module2 lines) ---"
    grep -n "module2" "$GRUB_CFG" | head -12 || true
else
    echo "WARNING: No UEFI grub.cfg found"
fi

echo ""
echo "=== Step 5: Rebuild ISO ==="

# Check for efiboot.img
EFIBOOT=$(find "${EXTRACT_DIR}" -name "efiboot.img" 2>/dev/null | head -1)

if [ -n "$EFIBOOT" ]; then
    # Relative path from extract dir
    EFIBOOT_REL=$(echo "$EFIBOOT" | sed "s|${EXTRACT_DIR}/||")
    echo "Found EFI boot image: $EFIBOOT_REL"

    genisoimage -o "$OUTPUT_ISO" \
        -v -r -J --joliet-long \
        -V "XCP-ng ${XCP_NG_MAJOR} Unattended" \
        -c boot/isolinux/boot.cat \
        -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e "$EFIBOOT_REL" -no-emul-boot \
        "${EXTRACT_DIR}/"
else
    echo "No EFI boot image found, BIOS-only ISO"
    genisoimage -o "$OUTPUT_ISO" \
        -v -r -J --joliet-long \
        -V "XCP-ng ${XCP_NG_MAJOR} Unattended" \
        -c boot/isolinux/boot.cat \
        -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "${EXTRACT_DIR}/"
fi

# Make hybrid bootable if isohybrid is available
if command -v isohybrid &>/dev/null; then
    if [ -n "$EFIBOOT" ]; then
        isohybrid --uefi "$OUTPUT_ISO" 2>/dev/null || isohybrid "$OUTPUT_ISO" 2>/dev/null || true
    else
        isohybrid "$OUTPUT_ISO" 2>/dev/null || true
    fi
    echo "Made hybrid bootable"
fi

echo ""
echo "=== Done ==="
echo "Output ISO: $OUTPUT_ISO"
ls -lh "$OUTPUT_ISO"
