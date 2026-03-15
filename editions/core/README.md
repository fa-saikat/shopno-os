# Edition: `core`

## What This Edition Is

The `core` edition is ShopnoOS stripped to its functional minimum: a bootable, networkable, secure TTY environment. It is the foundation on which all other editions build — but it is also a complete, shippable product in its own right for server, container, and netboot use cases.

**Flavor:** `none` — there is no display server, no window manager, no display manager. You get a console.

## What It Includes

- Everything in `base/` (kernel, firmware, systemd, security tools)
- Essential CLI tools: network, storage, archiving, text processing
- OpenSSH server (enabled, hardened by default)
- Chrony (NTP), rsyslog, fail2ban, UFW
- `podman` for rootless container workloads (no Docker daemon)
- Security hardening via sysctl and SSH config drops

## What It Deliberately Excludes

| Excluded              | Reason                                    |
| --------------------- | ----------------------------------------- |
| Xorg / Wayland        | No display server — flavor responsibility |
| PipeWire / PulseAudio | Desktop audio — desktop edition           |
| NetworkManager GUI    | CLI tools only; `nmcli` available         |
| Bluetooth stack       | Disabled + not installed                  |
| Printing (CUPS)       | Not a server concern                      |
| KVM / QEMU / Docker   | Power-user tools — lives in `pro` edition |
| Any DE or WM          | Flavor layer only                         |

## Target Use Cases

- Minimal base for server builds (add your stack post-install)
- Container seed image (build leaner images on top)
- Netboot / PXE target
- ISO for headless embedded / VM deployments
- Starting point for testing and CI pipelines

## Build Command

```bash
./scripts/build/build.sh abrar-core
```

Output: `abrar-1.0-core-none-amd64-<YYYYMMDD>.iso`

## Package Lists

| File                           | Contents                                                     |
| ------------------------------ | ------------------------------------------------------------ |
| `abrar-core.list.chroot`       | Required CLI packages — always included                      |
| `abrar-core-tools.list.chroot` | Convenience tools — included by default, can be omitted for minimal builds |

## Hooks

| Hook                              | Stage  | Purpose                                                      |
| --------------------------------- | ------ | ------------------------------------------------------------ |
| `0010-core-hardening.hook.chroot` | chroot | Disable unused services, harden SSH + sysctl, set UFW defaults |
