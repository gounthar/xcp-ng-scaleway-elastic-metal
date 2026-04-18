# XCP-ng on Scaleway Elastic Metal

Scaleway doesn't offer XCP-ng in their OS catalog. This repo does it anyway.

Scripts for installing XCP-ng on Scaleway Elastic Metal servers via QEMU passthrough, then provisioning agent VMs on the running hypervisor. No BMC access needed. No console clicks. One script, one coffee, about an hour.

Companion to the [blog series on dev.to](https://dev.to/gounthar).

## Fair warning

These scripts worked for me on specific hardware (Dell PowerEdge R220, EM-A116X-SSD offer, fr-par-1 zone). They handle the happy path and a handful of known failure modes. They are not robust. Your mileage will vary — especially since Scaleway allocates Dell or HPE servers at random, and HPE servers in this offer are incompatible (see Known issues).

This is not a tutorial. It's automation built on top of thirty hours of discoveries.

## What's here

| Script | Purpose |
|--------|---------|
| `provision-scaleway.sh` | End-to-end: creates the server, installs XCP-ng, validates, tears down if something breaks |
| `install-via-qemu.sh` | Runs on the server in rescue mode: builds the ISO, installs XCP-ng via QEMU with disk passthrough, applies bare-metal fixes |
| `build-iso.sh` | Builds a custom XCP-ng netinstall ISO with an embedded answerfile (requires Docker) |
| `answerfile.xml` | Unattended install configuration for XCP-ng |
| `setup-vms.sh` | Creates a golden template VM on the running hypervisor, clones agent VMs from it |

## Quick start

```bash
# Full pipeline: create server → install XCP-ng → validate
ZONE=fr-par-1 ./provision-scaleway.sh --full

# Provision VMs on the running hypervisor
./setup-vms.sh <server-ip>
```

## Requirements

**Local machine:**
- `scw` CLI configured with Elastic Metal access
- SSH key at `~/.ssh/ai-workstation` (or set `SSH_KEY_PATH`)
- `sshpass`, `jq`, `curl`
- Docker (for `build-iso.sh`)

**Scaleway:**
- Elastic Metal quota (EM-A116X-SSD or equivalent)
- fr-par-1 zone recommended (see Known issues for fr-par-2 PXE problems)

## XCP-ng version

Pinned in `xcp-ng-version.env`, sourced by all scripts. Major version for mirror URLs is derived automatically.

```bash
# Use a specific build
XCP_NG_VERSION=8.3.0-20250710 ./provision-scaleway.sh --full
```

An [updatecli](https://www.updatecli.io/) manifest in `updatecli/manifest.yaml` tracks new builds on the XCP-ng mirror and can open a PR to bump the version automatically.

## Timing (measured March 2026, fr-par-1, Dell R220)

| Phase | Time |
|-------|------|
| XCP-ng install (rescue → running hypervisor) | ~10 min |
| VM fleet setup (bare host → 3 running VMs) | ~12 min |
| **Total: API call → SSH-ready agent VMs** | **~22 min** |

## What we learned the hard way

Thirty hours of discoveries, condensed:

1. **Hardware lottery** — Scaleway allocates Dell or HPE randomly. HPE ProLiant DL320e Gen8 v2 with the B120i controller is incompatible (writes fail under AHCI). Script detects this and exits early.
2. **Dell BIOS + GPT = crash** — Dell PowerEdge R220 BIOS 1.11.0 crashes with a General Protection Fault when scanning a GPT partition table in Legacy BIOS mode. Fix: convert GPT to MBR with `sgdisk --gpttombr`, reinstall GRUB.
3. **Answerfile location** — XCP-ng's installer resolves `file:///answerfile.xml` inside the initramfs, not the ISO root. Inject the answerfile into `install.img` via cpio concatenation.
4. **Open vSwitch, not Linux bridges** — XAPI expects OVS networking. Standard Linux bridge config (`BRIDGE=`, `TYPE=Bridge`) produces a system that boots but has no network.
5. **Scaleway injects monitoring** — Even on a custom OS installed via QEMU, Scaleway modifies the running system after the stop/start cycle. Plan accordingly.
6. **Use fr-par-1** — fr-par-2 has PXE-E32 TFTP timeout issues with Broadcom NICs. fr-par-1 uses iPXE and works reliably.
7. **Never install Ubuntu first** — Scaleway's Ubuntu creates RAID1 arrays that persist in the kernel's partition cache. XCP-ng's GRUB embeds wrong sector addresses. Always use the Custom install OS option to get clean disks.
8. **Don't use `reboot`** — Use `scw baremetal server stop` then `start`. A plain reboot doesn't let you control boot type.
9. **Dracut needs a config file** — `dracut --add-drivers` in a chroot silently skips drivers it deems unnecessary. Drop a `.conf` in `/etc/dracut.conf.d/` with `add_drivers+=` instead.
10. **`network_device=eth0` boot parameter** — Required when `answerfile=file://`. Without it the installer can't reach the repo.

## Known issues

- **fr-par-2 PXE**: Broadcom NICs get PXE-E32 TFTP open timeout on fr-par-2. Use fr-par-1.
- **HPE servers**: B120i controller rejects writes under AHCI. Script exits with a clear error on HPE hardware detection.
- **XAPI bridge IPs reset on vm-start**: Scripts re-apply network config after each `vm-start` call.
- **SSH stdout suppression**: Scaleway's default `.bashrc` kills non-interactive SSH sessions. The scripts work around this; see the blog series for the manual fix.

## License

MIT
