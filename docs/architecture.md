# Architecture

> ShopnoOS - a Debian Live-build based distribution designed for reproducible, multi-edition, multi-flavor ISO production from a single repository.

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [The Three-Layer Model](#2-the-three-layer-model)
3. [Repository Layout](#3-repository-layout)
4. [Layer Reference](#4-layer-reference)
   - [base/](#41-base)
   - [editions/](#42-editions)
   - [flavors/](#43-flavors)
   - [hardware/](#44-hardware)
   - [brand/](#45-brand)
   - [profiles/](#46-profiles)
   - [vars/](#47-vars)
5. [The Profile Composition Engine](#5-the-profile-composition-engine)
6. [Build Pipeline](#6-build-pipeline)
7. [Config Merge Order](#7-config-merge-order)
8. [Package Ownership Rules](#8-package-ownership-rules)
9. [ISO Naming Law](#9-iso-naming-law)
10. [Script Library](#10-script-library)
11. [In-ISO Tools](#11-in-iso-tools)
12. [Testing and Validation](#12-testing-and-validation)
13. [CI/CD](#13-cicd)
14. [Design Decisions and Antipatterns](#14-design-decisions-and-antipatterns)

---

## 1. Design Philosophy

ShopnoOS is built around one constraint: **every concern lives in exactly one place**.

The repository is structured so that:

- Adding a new desktop environment requires touching only `flavors/` and `profiles/`
- Adding development tooling requires touching only `editions/pro/` and `profiles/`
- Rebranding requires touching only `brand/`
- Building a different hardware variant requires only a profile change

This is enforced through directory separation, a lint script that catches package duplication across layers and build scripts that assemble the final live-build configuration from those layers mechanically - no manual assembly or copy-paste.

The consequence is that the repository can produce a large matrix of ISOs (editions x flavors x hardware targets x architectures) without any duplication. A bug fix in a base package list fixes it across all ISOs simultaneously.

**Golden Rule:** A package lives in exactly ONE place. If you find yourself copying a package list - you're doing it wrong.

---

## 2. The Three-Layer Model

Every ISO is the product of composing three orthogonal layers on top of a shared base:

```
┌─────────────────────────────────────────────┐
│                   FLAVOR                    │  What the OS looks/feels like
│         (GNOME, KDE, XFCE, minimal-x)       │  DE + display manager + theming
├─────────────────────────────────────────────┤
│                  EDITION                    │  What the OS does
│          (core, desktop, pro, edu)          │  Capability packages + config
├─────────────────────────────────────────────┤
│                    BASE                     │  What the OS is
│      (kernel, firmware, security, utils)    │  Shared by all ISOs - never edition-specific
└─────────────────────────────────────────────┘
```

An optional fourth layer sits alongside these:

```
┌─────────────────────────────────────────────┐
│                 HARDWARE                    │  Hardware-specific overlay (optional)
│          (nvidia, amd, vm, rpi)             │  Applied last - wins over all other layers
└─────────────────────────────────────────────┘
```

| Layer | Controls | Changes | Example Contents |
|-------|----------|---------|-----------------|
| `base/` | What the OS **is** | Rarely - only for universal concerns | kernel, firmware, systemd, apparmor, ufw |
| `editions/<n>/` | What the OS **does** | Per release cycle | xorg, pipewire, docker, build-essential |
| `flavors/<n>/` | What the OS **looks like** | Per user preference | gnome-shell, lightdm, plasma-desktop |
| `hardware/<n>/` | Hardware-specific additions | As hardware targets are added | nvidia-driver, open-vm-tools, rpi-firmware |

These layers are **not inherited at runtime** - they are composed at build time by the profile system into a single live-build configuration tree. The resulting ISO has no concept of layers; it simply contains the union of all package lists and the merged overlay filesystem.

---

## 3. Repository Layout

```
shopno-os/
│
├── .github/                        # CI/CD - GitHub Actions / Forgejo workflows
│   ├── workflows/
│   │   ├── build-iso.yml
│   │   ├── lint-packages.yml
│   │   └── release.yml
│   └── ISSUE_TEMPLATE/
│
├── build/                          # Live-build working directories and output ISOs
│   └── ${profile}/                 # One subdirectory per profile being built
│       ├── binary/
│       ├── cache/
│       ├── chroot/
│       ├── config/                 # Assembled lb config (do not edit manually)
│       ├── build.log
│       └── <distro>-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>[-<HW>].iso
│
├── brand/                          # All identity and visual assets - isolated here only
│   ├── identity/
│   │   ├── name.env                # DISTRO_NAME, DISTRO_ID, DISTRO_VERSION, DISTRO_CODENAME
│   │   ├── colors.env              # BRAND_COLOR_PRIMARY, BRAND_COLOR_ACCENT, etc.
│   │   └── urls.env                # DISTRO_WEBSITE, DISTRO_MIRROR_PRIMARY, etc.
│   ├── assets/
│   │   ├── logo/
│   │   │   ├── logo.svg            # primary (light backgrounds)
│   │   │   ├── logo-dark.svg       # inverted (dark backgrounds)
│   │   │   └── logo-mono.svg       # single-color (GRUB, Plymouth fallback)
│   │   ├── wallpapers/
│   │   │   ├── base/               # default wallpapers, available to all flavors
│   │   │   └── editions/           # edition-specific wallpaper variants
│   │   ├── icons/
│   │   │   └── shopno-os-icon-theme/
│   │   ├── grub/
│   │   │   ├── theme/
│   │   │   └── background.png      # 1920×1080 PNG, no alpha (GRUB limitation)
│   │   └── plymouth/
│   │       ├── theme/
│   │       └── logo.png            # RGBA PNG, 256×256 or 512×512
│   └── skel-branding/              # Overlaid onto /etc/skel for ALL editions
│       └── .config/gtk-3.0/bookmarks
│
├── base/                           # Shared by every ISO - change with care
│   ├── package-lists/
│   │   ├── shopno-os-base.list.chroot          # systemd, grub, cryptsetup, sudo, etc.
│   │   ├── shopno-os-hardware.list.chroot      # kernel, firmware-*, dkms, iw
│   │   ├── shopno-os-security.list.chroot      # apparmor, ufw, openssh, openvpn
│   │   └── shopno-os-utils.list.chroot         # curl, wget, git, vim, htop, jq, etc.
│   ├── config/
│   │   ├── archives/                       # APT repo injection for build and live system
│   │   │   ├── shopno-os.list.chroot           # repo URL used during debootstrap/chroot
│   │   │   ├── shopno-os.list.binary           # repo added to live system's sources.list.d/
│   │   │   ├── shopno-os.key.chroot            # GPG key for build-time apt
│   │   │   └── shopno-os.key.binary            # GPG key deployed into live system
│   │   └── includes.chroot/                # Files overlaid into the chroot filesystem
│   │       ├── etc/apt/preferences.d/shopno-os-pin
│   │       ├── etc/default/locale
│   │       ├── etc/hostname
│   │       ├── etc/os-release              # Generated by hook - do not edit manually
│   │       ├── etc/shopno-os-release
│   │       └── usr/share/shopno-os/base-version
│   ├── hooks/
│   │   ├── chroot/
│   │   │   ├── 0010-locale.hook.chroot
│   │   │   ├── 0020-kernel-cleanup.hook.chroot
│   │   │   ├── 0030-apparmor-enable.hook.chroot
│   │   │   └── 0090-stamp-build-info.hook.chroot   # writes /etc/os-release
│   │   └── binary/
│   │       └── 0010-embed-manifest.hook.binary
│   └── preseed/
│       └── shopno-os-base.cfg.chroot
│
├── editions/                       # Capability layer - one subdirectory per edition
│   ├── core/                       # Minimal CLI / server / container base
│   ├── desktop/                    # General-purpose GUI (no DE - that is a flavor)
│   ├── pro/                        # Developer / power-user workstation (future)
│   └── edu/                        # Education-focused (future)
│
├── flavors/                        # Experience layer - one subdirectory per DE
│   ├── gnome/
│   ├── kde/
│   ├── xfce/
│   └── minimal-x/                  # Openbox/ dwm/ i3 - no DE bloat
│
├── hardware/                       # Hardware-specific overlays - applied last
│   ├── nvidia/                     # NVIDIA proprietary driver stack
│   ├── amd/                        # AMD ROCm userspace
│   ├── vm/                         # open-vm-tools, virtualbox-guest, qemu-guest-agent
│   └── rpi/                        # Raspberry Pi / ARM (future)
│
├── profiles/                       # Build profiles - compose the above layers
│   ├── _template/                  # Copy this to create a new profile
│   ├── shopno-os-core/
│   ├── shopno-os-desktop-gnome/
│   ├── shopno-os-desktop-kde/
│   ├── shopno-os-desktop-xfce/
│   ├── shopno-os-pro-gnome/
│   └── shopno-os-pro-kde/
│
├── scripts/                        # All build tooling - never run live-build directly
│   ├── lib/                        # Shared library - sourced by all scripts
│   │   ├── common.sh               # logging, error traps, utility functions
│   │   ├── brand.sh                # loads brand/identity/*.env, exports DISTRO_* vars
│   │   ├── profile.sh              # profile loading and validation
│   │   ├── iso-name.sh             # ISO naming - the single source of truth
│   │   └── secrets.sh              # Loads secrets/*.env, exports vars, prints capability summary
│	│
│   ├── build/
│   │   ├── build.sh                # MAIN ENTRY POINT
│   │   ├── clean.sh
│   │   ├── prepare-lb-config.sh    # assembles live-build config from profile
│   │   ├── inject-packages.sh      # symlinks package lists into lb config tree
│   │   └── stamp-iso.sh            # embeds build metadata into ISO
│	│
│   ├── dev/
│   │   ├── new-edition.sh          # scaffold a new edition
│   │   ├── new-flavor.sh           # scaffold a new flavor
│   │   ├── new-profile.sh          # scaffold a new profile from _template
│   │   ├── lint-packages.sh        # check for duplicate packages across all lists
│   │   └── diff-editions.sh        # compare package sets between two editions
│	│
│   └── release/
│       ├── sign-iso.sh
│       ├── publish.sh
│       └── changelog-gen.sh
│
├── tools/                          # Applications installed into the live rootfs
│   ├── shopno-os-installer/            # Calamares config + installer hooks
│   ├── shopno-os-welcome/              # First-run welcome application (future)
│   ├── shopno-os-upgrade/              # Upgrade helper (/usr/bin/shopno-os-upgrade)
│   └── shopno-os-hw-detect/            # Post-install hardware detection (future)
│
├── tests/							# TODO
│   ├── smoke/ 
│   ├── lint/
│   └── fixtures/
│
├── vars/
│   ├── defaults.env                # Default ARCH, DISTRIBUTION, BOOTLOADERS, etc.
│   └── distributions.env           # Known Debian/Ubuntu base distributions
│
├── secrets/                        # LOCAL SECRETS - never committed, gitignored
│   ├── .gitkeep                    # Keeps the empty directory tracked
│   ├── signing.env					# ISO GPG signing key (copied from _template/signing.env.example)
│   └── _template                 	# Contains commited templates
│   	├── signing.env.example
│   	├── repo-signing.env.example
│   	├── mirror-credentials.env.example
│   	├── notary.env.example
│   	└── github-token.env.example
│
├── docs/
├── .envrc                          # direnv: auto-load brand vars on cd
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

---

## 4. Layer Reference

### 4.1 `base/`

The foundation shared by every ISO produced from this repository. Changes here affect every edition, every flavor and every hardware target simultaneously. Treat it accordingly.

**What belongs here:**

- Boot infrastructure: `grub`, `shim-signed`, `mokutil`, `efibootmgr`
- Init system: `systemd`, `systemd-timesyncd`, `dbus`
- Kernel and firmware: `linux-headers-amd64`, all `firmware-*` packages, `dkms`
- Security baseline: `apparmor`, `ufw`, `openssh-client/server`, `openvpn`
- Core utilities: `curl`, `wget`, `git`, `vim`, `bash-completion`, `jq`, `htop`
- APT infrastructure: `apt-transport-https`, `ca-certificates`, `gnupg`
- Locale and timezone tooling

**What does NOT belong here:**

- Anything GUI-related (Xorg, PipeWire, NetworkManager GUI - those are `editions/desktop/`)
- Any desktop environment package (those are `flavors/`)
- Hardware-specific drivers (those are `hardware/`)
- Any package that is only useful in one edition

**Directory structure:**

```
base/
├── package-lists/      	← one file per concern: base, hardware, security, utils
├── config/
│   ├── archives/       	← APT repo + GPG key for build-time and live system
│   └── includes.chroot/  	← files overlaid verbatim into the chroot
├── hooks/
│   ├── chroot/         	← numbered .hook.chroot files, run inside the chroot
│   └── binary/         	← run after chroot is squashed, against the binary image
└── preseed/            	← debconf preseed answers
```

The `0090-stamp-build-info.hook.chroot` hook writes `/etc/os-release` by calling `generate_os_release()` from `scripts/lib/brand.sh`. This file must never be placed in `includes.chroot/` - the hook generates it from live brand variables at build time.

---

### 4.2 `editions/`

The capability layer. An edition defines what the OS *does* - the purpose it is built for. Editions add packages and configuration on top of base to produce a functional system of a particular kind.

**Current editions:**

| Edition | Purpose | Key Packages |
|---------|---------|-------------|
| `core` | Minimal CLI, server, container base | server tooling, hardening config |
| `desktop` | General-purpose GUI workstation | xorg, pipewire, network-manager, flatpak, common apps |
| `pro` | Developer / power-user workstation | build-essential, docker, kvm, virt-manager, dev tools |
| `edu` | Education-focused *(future)* | educational software suite |

**What belongs in an edition:**

- Infrastructure for a class of use: Xorg and PipeWire for any GUI system, Docker and KVM for developers
- Configuration relevant to that use case: NetworkManager policy, audio routing, virtualization groups
- Applications universal to that use case: browsers, office suite, media players (for `desktop`)

**What does NOT belong in an edition:**

- Desktop environment shells - those are `flavors/`
- Display managers - owned by whichever flavor is being used
- GPU drivers - those are `hardware/`
- Anything already in `base/`

**Standard directory structure per edition:**

```
editions/<name>/
├── README.md                           	← mandatory: what this edition is and is NOT
├── package-lists/
│   └── shopno-os-<name>-<purpose>.list.chroot
├── config/
│   └── includes.chroot/
│       └── etc/shopno-os/edition           ← single-line file containing the edition name
└── hooks/
    └── chroot/
        └── <NNNN>-<purpose>.hook.chroot
```

The file `etc/shopno-os/edition` is deployed into the live system so that scripts and tools can identify the running edition at runtime without parsing `/etc/os-release`.

---

### 4.3 `flavors/`

The experience layer. A flavor defines what the OS *looks and feels like* - the desktop environment, display manager, theming, and per-user skeleton defaults.

**Current flavors:**

| Flavor | Desktop Environment | Display Manager |
|--------|--------------------|-----------------|
| `gnome` | GNOME Shell | GDM3 |
| `kde` | KDE Plasma | SDDM |
| `xfce` | XFCE 4 | LightDM |
| `minimal-x` | Openbox / dwm/ i3 | *(none - manual)* |

**What belongs in a flavor:**

- The DE shell and its core dependencies (`gnome-shell`, `plasma-desktop`, `xfce4`)
- The display manager for that DE (`gdm3`, `sddm`, `lightdm`)
- DE-specific application replacements (Dolphin instead of Nautilus in KDE)
- gschema overrides, dconf defaults, Plasma configuration
- Per-user skeleton files in `skel/` - copied to `/etc/skel` at build time

**What does NOT belong in a flavor:**

- Capability packages (Xorg, PipeWire, NetworkManager - those are `editions/desktop/`)
- GPU drivers - those are `hardware/`
- Applications not tied to the DE (those belong in the edition)

**Standard directory structure per flavor:**

```
flavors/<name>/
├── README.md
├── package-lists/
│   ├── shopno-os-flavor-<name>.list.chroot         ← DE core packages
│   ├── shopno-os-flavor-<name>-apps.list.chroot    ← DE-specific app replacements
│   └── shopno-os-display-manager.list.chroot       ← DM + screen locker
├── config/
│   └── includes.chroot/
│       ├── etc/shopno-os/flavor                    ← single-line file: the flavor name
│       └── usr/share/glib-2.0/schemas/         	← gschema overrides (GTK/GNOME DEs)
├── skel/                                       	← overlaid onto /etc/skel
│   └── .config/
└── hooks/
    └── chroot/
```

---

### 4.4 `hardware/`

Optional hardware-specific overlays. A hardware layer adds packages and configuration for a particular class of hardware - GPU drivers, hypervisor guest tools, ARM board support. It is selected per profile and applied last in the config merge order, meaning it can override any file from base, editions, or flavors.

**Current hardware layers:**

| Layer | Contents |
|-------|---------|
| `nvidia` | NVIDIA proprietary driver, optional CUDA packages, nouveau blacklist hook |
| `amd` | AMD ROCm userspace stack |
| `vm` | `open-vm-tools`, `virtualbox-guest-utils`, `qemu-guest-agent` *(future)* |
| `rpi` | Raspberry Pi / ARM board support *(future)* |

**Critical rule:** GPU drivers must never appear in `base/` or any edition. A driver baked into a shared layer installs on incompatible hardware in every ISO, producing broken systems that cannot be fixed without a full rebuild.

**Standard directory structure:**

```
hardware/<name>/
├── README.md
├── package-lists/
│   └── shopno-os-hw-<name>.list.chroot
└── hooks/
    └── chroot/
        └── 0010-<name>-setup.hook.chroot
```

---

### 4.5 `brand/`

All distribution identity and visual assets live exclusively in `brand/`. No file outside this directory may contain a hardcoded distribution name, version, color, URL, or logo path.

**Three identity files drive everything:**

| File | Contains |
|------|---------|
| `brand/identity/name.env` | `DISTRO_NAME`, `DISTRO_ID`, `DISTRO_VERSION`, `DISTRO_CODENAME`, `DISTRO_ID_LIKE`, `DISTRO_WEBSITE`, `DISTRO_BUGTRACKER` |
| `brand/identity/colors.env` | `BRAND_COLOR_PRIMARY`, `BRAND_COLOR_ACCENT`, `BRAND_COLOR_LIGHT`, `BRAND_COLOR_DARK` |
| `brand/identity/urls.env` | `DISTRO_MIRROR_PRIMARY`, `DISTRO_MIRROR_FALLBACK`, `DISTRO_DOCS_URL`, `DISTRO_RELEASE_URL` |

These are loaded by `scripts/lib/brand.sh` at the start of every build and exported into the environment. Every build script and hook receives them as environment variables without reading the files directly.

`/etc/os-release` is generated at build time by the `0090-stamp-build-info.hook.chroot` hook, which calls `generate_os_release()` from `brand.sh`. It is never written manually.

To fully rebrand the distribution: edit `brand/identity/name.env`, swap assets in `brand/assets/`, and rebuild. No other files need changing. See `docs/branding-guide.md` for the full checklist.

---

### 4.6 `profiles/`

Profiles are the composition engine. A profile declares which edition, flavor, hardware layer, architecture, and live-build parameters to combine, and the build system assembles the live-build configuration tree from that declaration.

**Profile structure:**

```
profiles/shopno-os-desktop-gnome/
├── profile.env       ← composition declaration
└── lb_config.sh      ← live-build config command for this profile
```

**`profile.env` example:**

```bash
DISTRO_EDITION="desktop"
DISTRO_FLAVOR="xfce"
DISTRO_HARDWARE="generic"
DISTRO_ARCH="amd64"
LB_DISTRIBUTION="trixie"
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi"
LB_MEMTEST="none"
```

`profile.env` declares intent only - it does not need to repeat values already covered by `vars/defaults.env`. The build system merges defaults first, then profile-specific overrides.

**Existing profiles:**

| Profile | Edition | Flavor | Hardware |
|---------|---------|--------|---------|
| `shopno-os-core` | core | none | generic |
| `shopno-os-desktop-gnome` | desktop | gnome | generic |
| `shopno-os-desktop-kde` | desktop | kde | generic |
| `shopno-os-desktop-xfce` | desktop | xfce | generic |
| `shopno-os-pro-gnome` | pro | gnome | generic |
| `shopno-os-pro-kde` | pro | kde | generic |

To add a new profile, copy `profiles/_template/` and edit `profile.env`. See `docs/adding-edition.md` or `docs/adding-flavor.md` for runbooks.

---

### 4.7 `vars/`

Default values shared across all profiles. A profile only needs to override what differs from the defaults.

```bash
# vars/defaults.env
DISTRO_ARCH="amd64"
LB_DISTRIBUTION="trixie"
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi"
LB_MEMTEST="none"
DISTRO_HARDWARE="generic"
```

```bash
# vars/distributions.env
# Known base distributions and their metadata
# Used by profile validation to catch typos
KNOWN_DISTRIBUTIONS="trixie bookworm bullseye jammy noble"
```

---

## 5. The Profile Composition Engine

When `build.sh` is invoked with a profile name, `prepare-lb-config.sh` assembles a complete live-build configuration tree from the individual layer directories. No layer is aware of the others - the composition happens entirely in the build script.

**Assembly sequence for profile `shopno-os-desktop-gnome`:**

```
1. Load vars/defaults.env
2. Load profiles/shopno-os-desktop-gnome/profile.env  (overrides defaults)
3. Load brand/identity/name.env  (exports DISTRO_* vars)
4. Create build/shopno-os-desktop-gnome/config/

5. Symlink package lists:
   base/package-lists/*                    → config/package-lists/
   editions/desktop/package-lists/*        → config/package-lists/
   flavors/gnome/package-lists/*           → config/package-lists/
   (hardware/generic skipped - no packages)

6. Merge includes.chroot/ overlays in order:
   base/config/includes.chroot/            (foundation)
   editions/desktop/config/includes.chroot/ (edition layer - can override base)
   flavors/gnome/config/includes.chroot/   (flavor layer - can override edition)
   (hardware/generic has no includes)

7. Merge hooks in order:
   base/hooks/chroot/*
   editions/desktop/hooks/chroot/*
   flavors/gnome/hooks/chroot/*

8. Copy bootloader config from editions/desktop/config/bootloaders/

9. Run lb config with assembled parameters

10. Stamp ISO name: shopno-os-1.0-desktop-gnome-amd64-20250301.iso
```

Package lists are symlinked rather than copied so that editing a source file is immediately reflected in the assembled config without needing to re-run preparation.

---

## 6. Build Pipeline

The main entry point is `scripts/build/build.sh`. Run it directly - never invoke `lb build` manually.

```bash
./scripts/build/build.sh <profile-name> [options]
```

**Options:**

| Option | Effect |
|--------|--------|
| `--no-clean` | Skip wiping `build/<profile>/` - uses cached chroot (faster iteration) |
| `--dry-run` | Print what would happen, do not execute |
| `--skip-lint` | Skip duplicate package check (not recommended) |
| `--skip-sign` | Skip GPG signing |
| `--jobs N` | Parallel jobs passed to `lb build` (default: `nproc`) |
| `--output-dir D` | Move final ISO to this directory (default: `build/output/`) |

**Pipeline stages in order:**

```
Stage 1   Validate environment
          └── Checks: running as root, live-build installed,
                      required commands available (lb, debootstrap,
                      xorriso, genisoimage, mksquashfs, gpg, jq)

Stage 2   Load brand identity
          └── sources scripts/lib/brand.sh
              └── loads brand/identity/{name,colors,urls}.env
              └── validates required vars and format rules
              └── exports all DISTRO_* and BRAND_* into environment

Stage 3   Load and validate profile
          └── sources scripts/lib/profile.sh
              └── loads vars/defaults.env
              └── loads profiles/<name>/profile.env
              └── validates DISTRO_EDITION, DISTRO_FLAVOR, DISTRO_ARCH

Stage 4   Lint package lists
          └── scripts/dev/lint-packages.sh
              └── scans all *.list.chroot files across all layers
              └── fails on any package appearing in more than one layer
              └── skippable with --skip-lint (not recommended)

Stage 5   Clean previous build
          └── scripts/build/clean.sh <profile>
              └── wipes build/<profile>/ entirely
              └── skippable with --no-clean for cache reuse

Stage 6   Prepare live-build config tree
          └── scripts/build/prepare-lb-config.sh
              └── creates build/<profile>/config/
              └── runs lb config with profile parameters

Stage 7   Inject package lists
          └── scripts/build/inject-packages.sh
              └── symlinks package lists from all layers into config/package-lists/
              └── merges includes.chroot/ overlays in layer order

Stage 8   Run lb build
          └── pushd build/<profile>/
              lb build --jobs N
              └── output logged to build/<profile>/build.log

Stage 9   Stamp ISO
          └── scripts/build/stamp-iso.sh
              └── embeds build metadata into ISO
              └── writes build-manifest.json

Stage 10  Sign ISO + generate checksums
          └── scripts/release/sign-iso.sh
              └── produces .sha256, .sha512, .gpg

Stage 11  Move to output directory
          └── ISO + checksums + manifest → build/output/
              (or --output-dir if specified)
```

**Build artifacts produced:**

```
build/output/
├── shopno-os-1.0-desktop-gnome-amd64-20250301.iso
├── shopno-os-1.0-desktop-gnome-amd64-20250301.iso.sha256
├── shopno-os-1.0-desktop-gnome-amd64-20250301.iso.sha512
├── shopno-os-1.0-desktop-gnome-amd64-20250301.iso.gpg
└── build-manifest.json
```

---

## 7. Config Merge Order

When multiple layers provide a file at the same path inside `includes.chroot/`, later layers win. Hardware always has final say.

| Priority | Layer | Overrides |
|----------|-------|-----------|
| 1 (lowest) | `base/config/includes.chroot/` | Nothing - it is the foundation |
| 2 | `editions/<n>/config/includes.chroot/` | Base files at the same path |
| 3 | `flavors/<n>/config/includes.chroot/` | Base and edition files |
| 4 (highest) | `hardware/<n>/config/includes.chroot/` | All previous layers |

Hooks follow the same order. All base hooks run before all edition hooks, which run before all flavor hooks, which run before all hardware hooks. Within each layer, hooks run in ascending numeric order (`0010-` before `0020-` before `0090-`).

This means a hardware hook can undo or override anything set by a base, edition, or flavor hook. This is intentional - hardware-specific setup often requires overriding generic defaults.

---

## 8. Package Ownership Rules

This is the law. Violations cause live-build conflicts and debugging sessions measured in hours.

| Package Type | Lives In | Never In |
|---|---|---|
| Kernel, firmware-*, dkms | `base/package-lists/shopno-os-hardware` | Anywhere else |
| systemd, grub, cryptsetup, sudo | `base/package-lists/shopno-os-base` | Anywhere else |
| apparmor, ufw, openssh, openvpn | `base/package-lists/shopno-os-security` | Editions or flavors |
| curl, wget, git, vim, htop | `base/package-lists/shopno-os-utils` | Anywhere else |
| xorg, pipewire, network-manager | `editions/desktop/package-lists/` | Base or flavors |
| flatpak, cups, common GUI apps | `editions/desktop/package-lists/` | Base or flavors |
| docker, kvm, build-essential | `editions/pro/package-lists/` | Desktop or base |
| gnome-shell, gdm3 | `flavors/gnome/package-lists/` | Editions - ever |
| kde-plasma-desktop, sddm | `flavors/kde/package-lists/` | Editions - ever |
| xfce4, lightdm | `flavors/xfce/package-lists/` | Editions - ever |
| DE-specific app replacements | `flavors/<n>/package-lists/` | Desktop edition |
| NVIDIA drivers | `hardware/nvidia/package-lists/` | Base - ever |
| AMD ROCm | `hardware/amd/package-lists/` | Base - ever |
| open-vm-tools, virtualbox-guest | `hardware/vm/package-lists/` | Base or editions |

**Enforcement:** `scripts/dev/lint-packages.sh` scans all `.list.chroot` files across all layers and fails the build if any package name appears in more than one layer. Run it before every commit. It also runs automatically in CI on every push via `lint-packages.yml`.

---

## 9. ISO Naming Law

Every ISO is named deterministically from build variables. Names are never constructed manually or renamed after the fact.

**Format:**

```
<ISO_PREFIX>-<DISTRO_VERSION>-<DISTRO_EDITION>-<DISTRO_FLAVOR>-<DISTRO_ARCH>-<BUILDDATE>[-<DISTRO_HARDWARE>].iso
```

**Examples:**

```
shopno-os-1.0-desktop-xfce-amd64-20250301.iso
shopno-os-1.0-desktop-gnome-amd64-20250301.iso
shopno-os-1.0-desktop-kde-amd64-20250301.iso
shopno-os-1.0-core-none-amd64-20250301.iso
shopno-os-1.0-pro-gnome-amd64-20250301-nvidia.iso
```

The hardware suffix is omitted when `DISTRO_HARDWARE="generic"`. `DISTRO_FLAVOR="none"` is used for the `core` edition which pairs with no flavor.

**Implemented in:** `scripts/lib/iso-name.sh` - sourced by `build.sh`, `stamp-iso.sh`, and `sign-iso.sh`. The ISO name is never constructed inline anywhere else. Checksum and signature filenames are derived from the ISO name by the same library.

See `docs/naming-law.md` for the full specification.

---

## 10. Script Library

All scripts source from `scripts/lib/` before doing any work. Direct invocation of `lb`, `debootstrap`, or any system tool outside of this library is prohibited.

| Script | Purpose |
|--------|---------|
| `scripts/lib/common.sh` | Logging (`log_info`, `log_warn`, `log_error`, `log_success`, `log_step`), error traps (`set -euo pipefail`), utility functions (`require_root`, `require_command`, `require_var`, `require_dir`), `shopno-os_run` wrapper |
| `scripts/lib/brand.sh` | Loads `brand/identity/*.env`, validates required vars, exports `DISTRO_*` and `BRAND_*` into environment, provides asset path helpers (`brand_logo_svg`, `brand_wallpaper_base`, `brand_grub_background`), provides `generate_os_release()` |
| `scripts/lib/profile.sh` | Loads `vars/defaults.env` then `profiles/<n>/profile.env`, validates edition/flavor/hardware against known values, exports profile vars |
| `scripts/lib/iso-name.sh` | `iso_name()`, `iso_stem()`, `iso_checksum_filename()`, `iso_signature_filename()` - all ISO naming logic lives here |

`common.sh` must be sourced first. `brand.sh` requires `common.sh`. `profile.sh` requires both. The sourcing order in `build.sh` is:

```bash
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/brand.sh"
source "${LIB_DIR}/iso-name.sh"
# then later:
source "${LIB_DIR}/profile.sh"
```

`brand.sh` is idempotent - it is safe to source multiple times in the same process. An `SHOPNOOS_BRAND_LOADED` guard prevents double-loading.

---

## 11. In-ISO Tools

`tools/` contains applications that are installed into the live rootfs and the installed system. They are built from source in this repository and installed via hooks or package lists.

| Tool | Installed As | Purpose |
|------|-------------|---------|
| `shopno-os-installer` | Calamares configuration | Graphical installer with custom modules and branding |
| `shopno-os-welcome` | First-run application | Post-boot welcome screen, driver/codec install helpers |
| `shopno-os-upgrade` | `/usr/bin/shopno-os-upgrade` | Guided system upgrade helper script |
| `shopno-os-hw-detect` | Post-install hook | Detects hardware class, suggests appropriate hardware layer |

These tools reference brand variables from the environment at runtime - they do not hardcode distribution names.

---

## 12. Testing and Validation

```
tests/
├── smoke/
│   ├── test-iso-boots.sh           # QEMU boot test (UEFI-only) - verifies ISO reaches multi-user.target cleanly
│   └── test-packages-present.sh    # Rootless artifact check - installed set vs floor + critical-package list
├── lint/
│   ├── check-duplicate-packages.sh # Same logic as lint-packages.sh - run in CI
│   ├── check-no-hardcoded-names.sh # Scans all files outside brand/ for hardcoded names
│   └── check-brand-vars-used.sh    # Confirms every declared DISTRO_* var is consumed
└── fixtures/
    └── expected-package-counts.json  # Per-profile floors + critical packages; per-profile validation flags
```

**Smoke tests** run against the built ISO. `test-iso-boots.sh` boots the ISO headlessly under QEMU and greps the serial log for the boot-marker service's verdict — by design it exercises the **UEFI (grub-efi) boot path only**. The legacy-BIOS (ISOLINUX/syslinux) path has no serial configuration yet, so a BIOS boot would hang silently waiting for keyboard input; see issue #30 before trusting any non-UEFI result from this gate.

`test-packages-present.sh` answers the complementary question — does the ISO *contain* what its layers declared — by extracting the squashfs **without root** (xorriso, with a 7z fallback for images xorriso 1.5.x can't parse; single-file `unsquashfs` of `var/lib/dpkg/status`, never a loop mount, so it runs in unprivileged CI). It deliberately checks a **floor plus a critical-package list, not exact counts**: exact counts go stale on every upstream Debian change and train people to bump numbers blindly, while a floor catches catastrophic drops and the critical list catches layer-merge regressions deterministically. Expectations live in `expected-package-counts.json`, which records per-profile `validated_against_real_iso` flags — a floor derived only from declared lists (unvalidated) is intentionally weaker than one recalibrated from a real build, and the flag says which is which.

**Lint tests** run on every push and do not require a build. They are fast and catch the most common classes of error: duplicate packages, hardcoded names, and unused brand variables.

---

## 13. CI/CD

Three workflows in `.github/workflows/`:

| Workflow | Trigger | Does |
|----------|---------|------|
| `lint-packages.yml` | Every push, every PR | Runs all `tests/lint/` scripts; fails fast on any violation |
| `build-iso.yml` | PRs targeting `dev`, manual dispatch | Matrix build (`core` + `desktop-xfce`, independent verdicts) with package gate blocking and boot gate metric-first; see `docs/ci-cd.md` |
| `release.yml` | — (deliberately not built) | Tag-triggered release automation declined, not deferred: phases run locally per `docs/release-process.md`, CI's role ends at proof |

`build-iso.yml` gates pull requests targeting `dev` — a build proves the PR before it lands. Pushes to `main` intentionally do not rebuild (proven bits are promoted, not re-proven — see `docs/release-process.md` §1.5). Manual dispatch builds any single profile, including `gaming-xfce`, which never runs unasked.

Build artifacts from `build-iso.yml` are uploaded as workflow artifacts and retained for 7 days. Release artifacts reach the mirror via `scripts/release/publish.sh`, run locally as part of the manual release checklist.

See `docs/ci-cd.md` for the full workflow documentation.

---

## 14. Design Decisions and Antipatterns

### Decisions

Formal Architecture Decision Records live in `docs/decisions/`. Key decisions:

- ~~**ADR 001 - Edition vs Flavor separation:** The capability/experience split ensures that adding a new DE does not require touching any capability configuration, and that adding new developer tools does not affect any DE.~~
- ~~**ADR 002 - No packages in overlays:** `includes.chroot/` is for config files only. Packages must be declared in `package-lists/` files so the lint script can catch duplicates. `.deb` files dropped into overlays bypass package management entirely.~~
- ~~**ADR 003 - Hardware as a separate layer:** GPU drivers and hardware-specific packages are not in `base/` because base packages install on every system. A separate hardware layer means drivers are opt-in at the profile level.~~
- **ADR-001 - Profile-based composition engine over flat `auto/config`:** the existing base/edition/flavor/hardware composition already produces an edition×flavor×hardware matrix with zero duplication — something a flat scaffold has no way to express without copy-pasting package lists per profile, reintroducing the exact duplication the Golden Rule prevents.
- **ADR-002 - Boot gate scoped to `multi-user.target`, not the edition's default target:** keeps one marker unit working identically across core/desktop/gaming, decoupled from `graphical.target`'s high-variance Xorg/LightDM chain under QEMU software rendering.
- **ADR-003 - Artifact-derived, rootless package-presence verification, floor + critical-list strictness:** truth comes from the built squashfs's `dpkg` status, never from re-summing source package lists; extraction requires no root; exact package counts are avoided because they go stale on every upstream Debian dependency change and train people to bump numbers blindly.

### Antipatterns

These patterns have caused real problems and are explicitly prevented by the structure:

| Antipattern | Why It Breaks Things | How It Is Prevented |
|---|---|---|
| Packages installed in hooks | Bypasses lint; creates undeclared dependencies; fails silently on package name changes | Lint script flags any `apt-get install` or `dpkg -i` in hooks |
| `.deb` files in `includes.chroot/` | Bypasses dpkg dependency resolution; silently stale on rebuild | Branding guide and flavor runbook explicitly document the correct alternatives |
| Hardcoded distribution names outside `brand/` | Rebrand requires grep-and-replace across repo | `check-no-hardcoded-names.sh` fails CI on any match |
| Constructing ISO names inline | Different scripts produce different names; artifacts become untrackable | All code uses `iso_name()` from `iso-name.sh`; no other construction is permitted |
| Running `lb build` directly | Skips lint, brand loading, package injection, signing | `build.sh` is the only entry point; CI enforces this |
| Writing `/etc/os-release` in `includes.chroot/` | Gets overwritten by the stamp hook; creates confusing stale state | Hook generates it at build time; `check-no-hardcoded-names.sh` catches manual copies |
| GPU drivers in `base/` | Installs incompatible drivers on every system; unrecoverable without rebuild | Hardware layer separation enforced by directory structure and lint |

---

*"The structure is the documentation. If you have to explain why a file is in a directory, it's in the wrong directory."*
