# XCP-ng on Scaleway Elastic Metal

Scripts for installing XCP-ng on Scaleway Elastic Metal servers via QEMU, and provisioning agent VMs. Companion to the [blog series](https://dev.to/gounthar).

## Fair warning

These scripts worked for me on a specific hardware configuration (Dell PowerEdge R220, EM-A116X-SSD offer, fr-par-2 zone). They are anything but robust. They handle the happy path and a few known failure modes, but there are plenty of edge cases that will trip them up. Your mileage will vary. This is not a tutorial.

## What's here

| Script | Purpose |
|--------|---------|
| `provision-scaleway.sh` | Creates an Elastic Metal server, boots rescue, installs XCP-ng, validates |
| `install-via-qemu.sh` | Runs on the server in rescue mode: builds ISO, installs XCP-ng via QEMU, applies bare-metal fixes |
| `build-iso.sh` | Builds a custom XCP-ng netinstall ISO with an embedded answerfile |
| `answerfile.xml` | XCP-ng automated install configuration |
| `setup-vms.sh` | Creates a golden template VM, installs tools, clones agent VMs |

## Quick start

```bash
# Full pipeline: create server, install XCP-ng, validate
ZONE=fr-par-1 ./provision-scaleway.sh --full

# Then provision VMs on the running XCP-ng host
./setup-vms.sh <server-ip>
```

## XCP-ng version

The XCP-ng version lives in `xcp-ng-version.env`, sourced by all scripts. The major version for mirror URLs is derived automatically. To use a different build:

```bash
XCP_NG_VERSION=8.3.0-20250710 ./provision-scaleway.sh --full
```

An [updatecli](https://www.updatecli.io/) manifest in `updatecli/manifest.yaml` can automatically detect new builds on the XCP-ng mirror and open a PR to bump the version.

## Requirements

- Scaleway account with Elastic Metal access
- `scw` CLI configured
- SSH key at `~/.ssh/ai-workstation` (or set `SSH_KEY_PATH`)
- `sshpass`, `jq`, `curl` on local machine

## Timing (measured March 2026)

| Phase | Time |
|-------|------|
| XCP-ng install (rescue to running hypervisor) | ~10 min |
| VM fleet setup (bare host to 3 running VMs) | ~12 min |
| **Total: API call to SSH-ready agent VMs** | **~22 min** |

## Known issues

- Scaleway fr-par-2 has PXE-E32 TFTP timeout issues with Broadcom NICs — use fr-par-1
- HPE servers in the EM-A116X-SSD offer are incompatible with XCP-ng (B120i controller)
- Dell PowerEdge R220 BIOS crashes on GPT — scripts convert to MBR automatically
- XAPI resets internal bridge IPs on vm-start — scripts re-apply after each start

## License

MIT
