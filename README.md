# NetCoreOS

**A network operating system CLI, packaged as a bootable Debian Live ISO.**

Boot a spare PC, VM, or USB stick straight into a switch/router/firewall command shell — no desktop, no distro setup. VLANs, L3 routing (OSPF, BGP, VRRP via FRR), a stateful firewall, DHCP (v4/v6), and VXLAN/GRE/WireGuard/IPsec tunnels, all from one CLI — plus an optional browser control panel.

![Version](https://img.shields.io/badge/version-0.1--beta-orange)
![Platform](https://img.shields.io/badge/platform-Debian%20Live-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Status](https://img.shields.io/badge/status-beta-red)

> ⚠️ **Beta software.** Test any config change — especially firewall/ACL rules — on a spare TTY before relying on it in production. See [Security notes](#security-notes) below.

---

## Table of contents

- [Why NetCoreOS](#why-netcoreos)
- [Features](#features)
- [What's in this repo](#whats-in-this-repo)
- [Quick start](#quick-start)
- [First boot](#first-boot)
- [Persistence (save config across reboots)](#persistence-save-config-across-reboots)
- [CLI overview](#cli-overview)
- [Security notes](#security-notes)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Why NetCoreOS

Ever needed a full router/switch/firewall for a lab, a homelab, or a teaching environment — without buying hardware or wrestling with raw `iproute2`/`nftables`/FRR configs by hand? NetCoreOS wraps all of that behind a single, familiar, Cisco-like command shell that boots directly on commodity x86 hardware or in any VM.

## Features

| Area | What you get |
|---|---|
| **Switching** | VLANs, STP, port security, L2 switch mode |
| **Routing** | OSPF, BGP, static routing, route-maps, prefix-lists, BFD, RPKI, VRF |
| **High availability** | VRRP |
| **Firewall / NAT** | ACLs, port forwarding, port/IP blocking |
| **DHCP** | IPv4 and IPv6 |
| **Tunnels** | VXLAN, GRE, WireGuard, IPsec |
| **Operations** | `show running-config`, `show tech-support`, live `dashboard`, config backup/restore, command scheduling, bandwidth testing |
| **Management** | CLI over console/SSH, optional web UI (`web` command) |

## What's in this repo

| File | Purpose |
|---|---|
| `netcoreos.sh` | The OS itself — CLI, all commands, all logic |
| `netcoreos_webui.py` | Optional browser-based control panel |
| `build-netcoreos-iso.sh` | Builds the bootable `.iso` from a local Debian package repo |
| `setup-persistence.sh` | Prepares a USB partition so config survives a reboot |

> 📦 **You don't need to build anything to use NetCoreOS.** A prebuilt ISO is published under [Releases](../../releases) — download it and skip straight to [First boot](#first-boot). Building from source is only needed if you want to modify the OS yourself.

## Quick start

### Option A — just use it (recommended)

Download the ISO from [Releases](../../releases), verify it against the published SHA256, and flash it:

```bash
sha256sum netcoreos-0.1-beta.iso   # compare against the checksum on the release page
sudo dd if=netcoreos-0.1-beta.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

(or use [Balena Etcher](https://etcher.balena.io/) if you prefer a GUI). Replace `/dev/sdX` with your actual USB device — double-check with `lsblk` first, `dd` does not ask twice. Then jump to [First boot](#first-boot).

### Option B — build it yourself

`build-netcoreos-iso.sh` builds **fully offline**: it does *not* fetch packages from an online apt mirror. Instead it expects a local folder of `.deb` files (Debian **trixie**, `amd64`) and builds a local package repo from them with `apt-ftparchive` before running `debootstrap` against it. In practice this means:

- You (or a script) must **manually download every required `.deb` package — including transitive dependencies** — and place them in the local repo folder the script expects (see `LOCAL_REPO` near the top of the script).
- Plain `apt install <package>` on the build machine is **not enough on its own** — that installs packages for the build host, it doesn't populate the local repo the ISO's rootfs is built from. You need the actual `.deb` files sitting in that folder.
- A convenient way to collect them (on a Debian trixie/amd64 machine with internet access) is `apt-get install --download-only` or `apt-get download <pkg>` for the full package list, or mirroring tools like `apt-mirror`/`debmirror` — check the package list near the top of `build-netcoreos-iso.sh` for exactly what's needed.

Once the local repo is populated:

```bash
sudo bash build-netcoreos-iso.sh
```

This debootstraps a minimal rootfs from that local repo, installs `netcoreos.sh` and `netcoreos_webui.py` into it, configures auto-login and SSH, and produces a bootable hybrid (BIOS + EFI) ISO.

## First boot

- Console (tty1–tty6) auto-logs in and drops straight into the NetCoreOS CLI — no Linux login prompt, just the NCOS password.
- SSH is enabled; log in as `root`.
- **Default password (both NCOS and Linux/SSH): `ncos`.** This is the same password for both, by design — one thing to remember. **Change it immediately:**
  ```
  change password
  ```

By default, this is a **live, non-persistent** session: a reboot wipes everything. See the next section to make changes stick.

## Persistence (save config across reboots)

```bash
sudo bash setup-persistence.sh /dev/sdX   # the USB device, not a partition
```

Then boot the **"NetCoreOS — Persistent Mode"** entry from the GRUB menu. Inside the CLI, save what should re-apply on every boot:

```
write
boot-persist enable
```

## CLI overview

Run `help` at any time to list everything available in the current mode. A few starting points:

```
switch              # L2 switch mode (VLANs, STP, port security, ...)
switch-mls          # switch + L3 inter-VLAN routing
router              # full router mode (OSPF, BGP, VRRP, NAT, VRF, ...)
firewall            # ACLs, NAT, port blocking

show running-config # everything currently configured, in one place
show tech-support   # version + health + config + recent log, for bug reports
dashboard           # live-refreshing status screen (Ctrl+C to exit)
web                 # start the browser control panel
```

**Rescue access** — a guaranteed plain Debian shell, independent of NCOS, no password — can be enabled from inside the CLI:

```
console rescue enable
```

Reachable afterward via `Ctrl+Alt+F9` on the physical console.

## Security notes

- **Change the default password (`ncos`) immediately** on any machine reachable over a network. SSH is on by default.
- `console rescue enable` creates a passwordless local account reachable only from the physical console (SSH to it is locked). Anyone with physical keyboard access can reach it — a deliberate trade-off for guaranteed recovery, similar in spirit to GRUB rescue mode. Don't enable it on hardware you don't physically control.
- This is beta software with direct control over firewall/NAT/routing on the host. Review `show running-config` and test ACL/firewall changes on a spare TTY/session before trusting them.

## Roadmap

- [ ] Persistent config profiles / multi-boot config sets
- [ ] Expanded `show tech-support` diagnostics
- [ ] More web UI coverage of CLI features
- [ ] Community-contributed example configs (VXLAN fabric, BGP lab, etc.)

Have an idea or found a bug? Open an [issue](../../issues).

## Contributing

Issues and pull requests are welcome:

1. Fork the repo and create a branch for your change
2. Test CLI changes on a spare TTY/VM before submitting — this touches live networking config
3. Open a PR describing what changed and why

For bug reports, please attach the output of `show tech-support` — it saves a lot of back-and-forth.

## License

See [`LICENSE`](LICENSE) (MIT).

---

**Author:** Silent Cell
