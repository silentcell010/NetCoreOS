NetCoreOS

A network operating system CLI, packaged as a bootable Debian Live ISO.

Boot a spare PC, VM, or USB stick straight into a switch/router/firewall command shell — no desktop, no distro setup. VLANs, L3 routing (OSPF, BGP, VRRP via FRR), a stateful firewall, DHCP (v4/v6), and VXLAN/GRE/WireGuard/IPsec tunnels, all from one CLI — plus an optional browser control panel.

"Version" (https://img.shields.io/badge/version-0.1--beta-orange)
"Platform" (https://img.shields.io/badge/platform-Debian%20Live-blue)
"License" (https://img.shields.io/badge/license-MIT-lightgrey)
"Status" (https://img.shields.io/badge/status-beta-red)

«⚠️ Beta software. Test any config change — especially firewall/ACL rules — on a spare TTY before relying on it in production. See "Security notes" (#security-notes) below.»

---

Table of contents

- "Why NetCoreOS" (#why-netcoreos)
- "Features" (#features)
- "What's in this repo" (#whats-in-this-repo)
- "Quick start" (#quick-start)
- "First boot" (#first-boot)
- "Persistence (save config across reboots)" (#persistence-save-config-across-reboots)
- "CLI overview" (#cli-overview)
- "Security notes" (#security-notes)
- "Roadmap" (#roadmap)
- "Contributing" (#contributing)
- "License" (#license)

Why NetCoreOS

Ever needed a full router/switch/firewall for a lab, a homelab, or a teaching environment — without buying hardware or wrestling with raw "iproute2"/"nftables"/FRR configs by hand?

NetCoreOS wraps all of that behind a single, familiar, Cisco-like command shell that boots directly on commodity x86 hardware or in any VM.

The operating system and its runtime components are distributed primarily through the bootable NetCoreOS ISO.

Features

Area| What you get
Switching| VLANs, STP, port security, L2 switch mode
Routing| OSPF, BGP, static routing, route-maps, prefix-lists, BFD, RPKI, VRF
High availability| VRRP
Firewall / NAT| ACLs, port forwarding, port/IP blocking
DHCP| IPv4 and IPv6
Tunnels| VXLAN, GRE, WireGuard, IPsec
Operations| "show running-config", "show tech-support", live "dashboard", config backup/restore, command scheduling, bandwidth testing
Management| CLI over console/SSH, optional web UI ("web" command)

What's in this repo

The repository contains the public build, configuration, and distribution components of NetCoreOS.

The main NetCoreOS CLI and optional Web UI are bundled inside the released ISO rather than being distributed as standalone source files in this repository.

Component| Purpose
"build-netcoreos-iso.sh"| Builds the bootable NetCoreOS ".iso" from the required local Debian package repository and bundled system components
"setup-persistence.sh"| Prepares a USB partition so NetCoreOS configuration can survive reboots
"LICENSE"| MIT license

«📦 You don't need to build anything to use NetCoreOS. A prebuilt ISO is published under "Releases" (../../releases). Download it and skip straight to "First boot" (#first-boot).

The NetCoreOS CLI and optional Web UI are included inside the ISO and are not provided as standalone files in this repository.»

Quick start

Option A — just use it (recommended)

Download the ISO from "Releases" (../../releases), verify it against the published SHA256, and flash it:

sha256sum netcoreos-trixie-amd64.iso

Compare the result against the checksum published on the release page.

Then write the ISO to a USB device:

sudo dd if=netcoreos-trixie-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync

«⚠️ Replace "/dev/sdX" with your actual USB device. Double-check the device with "lsblk" first — "dd" does not ask twice.»

Alternatively, use a graphical USB imaging tool such as "Balena Etcher" (https://etcher.balena.io/) if you prefer.

After flashing the ISO, continue to "First boot" (#first-boot).

Option B — build it yourself

"build-netcoreos-iso.sh" is intended for building the NetCoreOS bootable ISO from the required local Debian packages and the components included by the build system.

The build process is designed to work from a local package repository rather than relying on an online apt mirror during the ISO build.

You must provide the required Debian ".deb" packages, including their dependencies, in the local repository expected by the build script.

On a Debian trixie/amd64 build machine with internet access, packages can be collected using tools such as:

apt-get install --download-only <package>

or:

apt-get download <package>

After the local package repository has been populated, run:

sudo bash build-netcoreos-iso.sh

The resulting ISO can then be written to a USB device or used directly in a VM.

«Note: The standalone "netcoreos.sh" and "netcoreos_webui.py" files are not required to be present in the repository checkout. The released ISO contains the runtime components needed to operate NetCoreOS.»

First boot

- Console (tty1–tty6) auto-logs in and drops straight into the NetCoreOS CLI — no Linux login prompt, just the NCOS password.
- SSH is enabled; log in as "root".
- Default password (both NCOS and Linux/SSH): "ncos". This is the same password for both, by design — one thing to remember. Change it immediately:

change password

By default, this is a live, non-persistent session: a reboot wipes everything. See the next section to make changes stick.

Persistence (save config across reboots)

Prepare the USB device with:

sudo bash setup-persistence.sh /dev/sdX

«Use the USB device, not an individual partition.»

Then boot the "NetCoreOS — Persistent Mode" entry from the GRUB menu.

Inside the CLI, save what should be re-applied on every boot:

write
boot-persist enable

CLI overview

Run "help" at any time to list everything available in the current mode.

A few starting points:

switch

L2 switch mode — VLANs, STP, port security, and related features.

switch-mls

Switch + L3 inter-VLAN routing.

router

Full router mode — OSPF, BGP, VRRP, NAT, VRF, and related routing features.

firewall

ACLs, NAT, and port blocking.

Useful operational commands include:

show running-config
show tech-support
dashboard
web

"dashboard" opens the live status screen. Press "Ctrl+C" to exit.

The "web" command starts the optional browser control panel when the Web UI is available.

Rescue access

A guaranteed plain Debian shell, independent of NCOS, can be enabled from inside the CLI:

console rescue enable

After enabling it, the rescue console is reachable via:

Ctrl+Alt+F9

on the physical console.

Security notes

- Change the default password ("ncos") immediately on any machine reachable over a network. SSH is enabled by default.
- "console rescue enable" creates a passwordless local account reachable only from the physical console. SSH access to it is locked.
- Anyone with physical keyboard access can reach the rescue environment after it is enabled. This is a deliberate recovery mechanism, similar in spirit to a GRUB rescue environment.
- Do not enable rescue access on hardware you do not physically control.
- NetCoreOS is beta software with direct control over firewall, NAT, and routing configuration on the host. Review "show running-config" and test ACL/firewall changes on a spare TTY/session before trusting them in production.

Roadmap

- [ ] Persistent config profiles / multi-boot config sets
- [ ] Expanded "show tech-support" diagnostics
- [ ] More web UI coverage of CLI features
- [ ] Community-contributed example configs (VXLAN fabric, BGP lab, etc.)
- [ ] Improved installation and upgrade workflow
- [ ] Additional hardware compatibility testing

Have an idea or found a bug? Open an "issue" (../../issues).

Contributing

Issues and pull requests are welcome.

1. Fork the repo and create a branch for your change.
2. Test CLI changes on a spare TTY/VM before submitting — this software directly controls live networking configuration.
3. Open a PR describing what changed and why.

For bug reports, please attach the output of:

show tech-support

This provides useful version, health, configuration, and recent log information for troubleshooting.

«Source distribution note: The NetCoreOS runtime CLI and optional Web UI are currently distributed as components of the bootable ISO rather than as standalone source files in this repository.»

License

See ""LICENSE"" (LICENSE) (MIT).

---

Author: Silent Cell