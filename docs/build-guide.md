# Build Guide

> Step-by-step: how to build an ShopnoOS ISO from source.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Clone the Repository](#2-clone-the-repository)
3. [Understand the Available Profiles](#3-understand-the-available-profiles)
4. [Your First Build](#4-your-first-build)
5. [What the Build Does Internally](#5-what-the-build-does-internally)
6. [Build Output](#6-build-output)
7. [Build Options Reference](#7-build-options-reference)
8. [Common Build Scenarios](#8-common-build-scenarios)
9. [What to (Re)build After a Change](#9-what-to-rebuild-after-a-change)
10. [Iterating on a Build](#10-iterating-on-a-build)
11. [Troubleshooting](#11-troubleshooting)
12. [What Not to Do](#12-what-not-to-do)

---

## 1. Prerequisites

### Host System

Builds must run on a **Debian-based host** (Debian 13 trixie recommended). ~~Ubuntu works~~. Building inside a VM works and is actually preferred for isolation - the build process modifies the host filesystem during chroot operations and requires root.

### Required Packages

```bash
sudo apt update
sudo apt install --no-install-recommends \
    live-build \
    debootstrap \
    xorriso \
    genisoimage \
    squashfs-tools \
    gpg \
    jq \
    curl \
    git
```

Verify live-build is available:

```bash
lb --version
# Expected: live-build 20230502 or newer
```

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8 GB+ |
| Free disk space | 20 GB | 40 GB+ |
| CPU cores | 2 | 4+ (use `--jobs`) |
| Internet | Required | Fast connection speeds up `debootstrap` significantly |

The build process downloads packages from Debian mirrors during the chroot stage. Build time on a fast machine with a warm apt cache is approximately 15–30 minutes. Cold builds with no cache on a slow connection can take over an hour.

### GPG Key (for signing)

If you intend to sign the ISO (default behaviour), you need a GPG key available to the root user:

```bash
sudo gpg --list-keys
```

If none is present, either create one or use `--skip-sign` during development. See `docs/release-process.md` for signing setup.

---

## 2. Clone the Repository

```bash
git clone https://github.com/JaduPC/shopno-os.git
cd shopno-os
```

Optionally, if you use [direnv](https://direnv.net/), allow the `.envrc` to auto-load brand variables when you enter the directory:

```bash
direnv allow
```

This is optional but convenient - it makes `DISTRO_*` variables available in your shell for inspecting profiles and running dev scripts without a full build.

---

## 3. Understand the Available Profiles

A profile is the unit of a build. Each profile specifies which edition, flavor, hardware layer, and architecture to combine. Before building, list what is available:

```bash
ls profiles/
```

```
_template/
shopno-os-core/
shopno-os-desktop-gnome/
shopno-os-desktop-kde/
shopno-os-desktop-xfce/
shopno-os-pro-gnome/
shopno-os-pro-kde/
```

Inspect a profile to see what it will build:

```bash
cat profiles/shopno-os-desktop-xfce/profile.env
```

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

The profile name maps directly to the ISO it produces. `shopno-os-desktop-gnome` produces `shopno-os-<VERSION>-desktop-gnome-amd64-<BUILDDATE>.iso`.

> **Core has no installer.** `shopno-os-core` boots a live session for rescue, inspection, and container-seed use, but nothing installs it to disk (desktop editions ship Calamares for that). This is a known limitation with no users attached, not an oversight — tracked, unscheduled.

**Profile quick reference:**

| Profile | What it builds |
|---------|---------------|
| `shopno-os-core` | Minimal CLI ISO, no desktop. Live-boot only — no installer (see note below) |
| `shopno-os-desktop-gnome` | Desktop ISO with GNOME |
| `shopno-os-desktop-kde` | Desktop ISO with KDE Plasma |
| `shopno-os-desktop-xfce` | Desktop ISO with XFCE |
| `shopno-os-pro-gnome` | Developer workstation ISO with GNOME |
| `shopno-os-pro-kde` | Developer workstation ISO with KDE Plasma |

---

## 4. Your First Build

**The build must run as root.** The live-build chroot process requires it.

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-xfce
```

That's the full command. The script handles everything: loading brand identity, assembling the live-build config tree, linting package lists, running `lb build`, stamping the ISO, signing, and moving the output to `build/output/`.

To verify what would happen without executing anything:

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-xfce --dry-run
```

Dry run prints every step and the final ISO filename without touching the filesystem.

---

## 5. What the Build Does Internally

Running `build.sh` executes these stages in order:

**Stage 1 - Validate environment**

Checks that the script is running as root and that all required commands are available (`lb`, `debootstrap`, `xorriso`, `genisoimage`, `mksquashfs`, `gpg`, `jq`). Fails immediately if anything is missing.

**Stage 2 - Load brand identity**

Sources `scripts/lib/brand.sh`, which reads `brand/identity/name.env`, `colors.env`, and `urls.env`. Validates that all required `DISTRO_*` variables are present and correctly formatted. Exports everything into the environment. All subsequent steps and hooks inherit these variables.

**Stage 3 - Load and validate profile**

Sources `scripts/lib/profile.sh`, which reads `vars/defaults.env` then `profiles/<name>/profile.env`. Validates `DISTRO_EDITION`, `DISTRO_FLAVOR`, and `DISTRO_ARCH` against known values. Derives the build directory path and ISO filename.

**Stage 4 - Lint package lists**

Runs `scripts/dev/lint-packages.sh`, which scans every `.list.chroot` file across `base/`, `editions/`, `flavors/`, and `hardware/`. Fails if any package name appears in more than one layer. This catches the most common class of build error before anything expensive happens.

**Stage 5 - Clean previous build**

Wipes `build/<profile>/` entirely to ensure a reproducible build. Skip with `--no-clean` when iterating (see [Iterating on a Build](#10-iterating-on-a-build)).

**Stage 6 - Prepare live-build config tree**

Runs `scripts/build/prepare-lb-config.sh`, which:
- Creates `build/<profile>/config/`
- Runs `lb config` with parameters assembled from the profile
- Copies bootloader configuration from the edition's `config/bootloaders/`

**Stage 7 - Inject package lists**

Runs `scripts/build/inject-packages.sh`, which symlinks package list files from all active layers into `build/<profile>/config/package-lists/` and merges `includes.chroot/` overlays in layer order (base → edition → flavor → hardware).

**Stage 8 - Run `lb build`**

Executes `lb build --jobs N` inside `build/<profile>/`. This is the longest stage. It:
- Runs `debootstrap` to create a minimal Debian chroot
- Installs all packages from the assembled package lists
- Applies all `includes.chroot/` file overlays
- Runs all numbered chroot hooks
- Squashes the chroot into a SquashFS filesystem
- Assembles the binary ISO image
- Runs binary-stage hooks

All output is logged to `build/<profile>/build.log`.

**Stage 9 - Stamp ISO**

Runs `scripts/build/stamp-iso.sh`, which embeds build metadata into the ISO and writes `build-manifest.json` containing the profile name, edition, flavor, hardware, arch, version, build date, and package counts.

**Stage 10 - Sign ISO + generate checksums**

Runs `scripts/release/sign-iso.sh`, which produces:
- `.sha256` checksum file
- `.sha512` checksum file
- `.gpg` detached signature

Skip with `--skip-sign` during development.

**Stage 11 - Move to output directory**

Moves the ISO, checksums, signature, and manifest to `build/output/` (or `--output-dir` if specified).

---

## 6. Build Output

After a successful build, `build/output/` contains:

```
build/output/
├── shopno-os-1.0-desktop-xfce-amd64-20250301.iso
├── shopno-os-1.0-desktop-xfce-amd64-20250301.iso.sha256
├── shopno-os-1.0-desktop-xfce-amd64-20250301.iso.sha512
├── shopno-os-1.0-desktop-xfce-amd64-20250301.iso.gpg
└── build-manifest.json
```

Verify the checksum before distributing:

```bash
cd build/output/
sha256sum -c shopno-os-1.0-desktop-xfce-amd64-20250301.iso.sha256
```

Inspect the build manifest:

```bash
jq . build/output/build-manifest.json
```

The intermediate build directory `build/<profile>/` is left intact after the build. It contains the full chroot, binary tree, and `build.log`. It can be safely deleted once you have the ISO. It is excluded from git via `.gitignore`.

---

## 7. Build Options Reference

```
./scripts/build/build.sh <profile-name> [options]
```

| Option | Default | Effect |
|--------|---------|--------|
| `--no-clean` | off | Skip wiping `build/<profile>/` before starting. Uses the cached chroot from the previous build. Much faster for iteration - see [§10](#10-iterating-on-a-build). |
| `--dry-run` | off | Print what every stage would do without executing anything. Does not require root. Useful for verifying a profile before committing to a full build. |
| `--skip-lint` | off | Skip the package duplicate check. Not recommended - lint failures indicate real conflicts that will break the build anyway, just later and with worse error messages. |
| `--skip-sign` | off | Skip GPG signing and checksum generation. Use during development when no GPG key is configured. |
| `--jobs N` | `nproc` | Number of parallel jobs passed to `lb build`. Defaults to the number of CPU cores. Reduce if the build host is under memory pressure. |
| `--output-dir D` | `build/output/` | Move the final ISO and artifacts to this directory instead of the default. |

---

## 8. Common Build Scenarios

### Build a XFCE desktop ISO

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-xfce
```

### Build a minimal server/CLI ISO

```bash
sudo ./scripts/build/build.sh shopno-os-core
```

### Build a developer workstation ISO (future)

```bash
sudo ./scripts/build/build.sh shopno-os-pro-kde
```

### Build with NVIDIA drivers (future)

Create a profile that sets `DISTRO_HARDWARE="nvidia"`, then:

```bash
sudo ./scripts/build/build.sh shopno-os-pro-gnome-nvidia
```

See `docs/adding-hardware.md` if the profile does not exist yet.

### Build a VM-testable ISO

```bash
# Use a profile with DISTRO_HARDWARE="vm" for open-vm-tools / virtualbox-guest / qemu-guest-agent
sudo ./scripts/build/build.sh shopno-os-desktop-xfce-vm
```

### Verify a profile without building

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-kde --dry-run
```

### Build without signing (development)

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-gnome --skip-sign
```

### Build with a custom output directory

```bash
sudo ./scripts/build/build.sh shopno-os-desktop-gnome --output-dir /srv/isos/
```

---

## 9. What to (Re)build After a Change

The rule: *an artifact gets rebuilt when something it consumes changed — nothing else.* CI enforces the same mapping via path filters (`build-iso.yml`, `container-build.yml`), so local discipline and CI agree.

| You changed | Rebuild ISO? | Rebuild container? | Why |
|---|---|---|---|
| `base/`, `editions/`, `hardware/` layers | Yes (affected profiles) | Only if `base/` or `editions/core/` | Both consume layers; container sees base+core only |
| `flavors/` (non-xfce) or desktop-only files | Yes (that profile) | No | Container never sees flavors |
| `profiles/<name>/`, `brand/` | Yes (that profile / all) | Only if core profile or brand identity | Brand flows into both |
| `scripts/build/build-container.sh`, `container-exclude.txt` | No | Yes | Container-only inputs |
| `scripts/build/build.sh`, `prepare-lb-config.sh`, `inject-packages.sh`, `stamp-iso.sh` | Yes | No | ISO pipeline internals |
| `scripts/lib/` | Yes, and container | Yes | Sourced by both builders — most blast radius per line |
| `tests/smoke/test-iso-*.sh`, fixtures | Re-run gates, no rebuild needed | — | Tests don't change artifacts |
| `tests/smoke/test-container-*.sh` | — | Re-run gate, no rebuild needed | Same |
| `docs/`, `tests/lint/` | No | No | Lint still runs; builds correctly skip |

When in doubt, build the cheaper artifact first (container: minutes; core ISO: ~30 min; desktop ISO: hours) — a green cheap gate before an expensive build is never wasted time.

---

## 10. Iterating on a Build

A full cold build takes 20–30 minutes minimum. When you are iterating on hooks, package lists or overlay files, you do not need to rebuild from scratch each time.

### Reuse the cached chroot

`--no-clean` skips wiping the build directory and reuses the existing chroot. Package installation and `debootstrap` are skipped if the chroot is intact. Only the changed hooks and overlays are reapplied.

```bash
# First build - full
sudo ./scripts/build/build.sh shopno-os-desktop-xfce

# Edit a hook or package list...

# Second build - reuses chroot, much faster
sudo ./scripts/build/build.sh shopno-os-desktop-xfce --no-clean
```

> **Note:** `--no-clean` is only safe when your changes are additive or limited to hooks and overlays. If you add or remove packages, the chroot no longer reflects the package lists and you need a clean build to get a correct result. When in doubt, do a clean build.

### Lint before building

Run the lint check in isolation before starting a build to catch package conflicts immediately:

```bash
./scripts/dev/lint-packages.sh
```

This does not require root and takes a few seconds.

### Inspect the chroot interactively

If you need to debug what is inside the chroot:

```bash
sudo chroot build/shopno-os-desktop-gnome/chroot /bin/bash
```

This drops you into the built chroot environment. Useful for verifying package installation, testing hooks manually, or inspecting generated config files. Exit with `exit` - do not leave the chroot modified and then expect `--no-clean` to produce a clean result.

### Compare package lists between editions

```bash
./scripts/dev/diff-editions.sh desktop pro
```

### Check for package duplicates without building

```bash
./scripts/dev/lint-packages.sh
```

---

## 11. Troubleshooting

### `lb build` fails early with a `debootstrap` error

The most common cause is a network issue during the initial Debian bootstrap. Check internet connectivity and Debian mirror availability:

```bash
curl -I https://deb.debian.org/debian
```

If you are behind a proxy, set `http_proxy` and `https_proxy` before running the build:

```bash
export http_proxy=http://proxy.example.com:3128
sudo -E ./scripts/build/build.sh shopno-os-desktop-gnome
```

The `-E` flag passes your environment (including proxy settings) through to sudo.

### Package not found during `apt-get install`

A package name in one of the `.list.chroot` files is incorrect or not available in the configured Debian release. Check the build log:

```bash
grep -i "unable to locate\|no installation candidate" build/<profile>/build.log
```

Fix the package name or add the appropriate APT repository to `base/config/archives/`.

### `lint-packages.sh` fails with duplicate package

A package appears in more than one layer's `.list.chroot` file. The error output names the package and the files it appears in. Remove it from all but the correct layer per the ownership rules in `docs/package-ownership.md`.

### Build fails with `Permission denied`

The build must run as root:

```bash
sudo ./scripts/build/build.sh <profile>
```

### Hook fails inside the chroot

The full hook output is in `build/<profile>/build.log`. Find the failing hook:

```bash
grep -A 10 "hook.chroot" build/<profile>/build.log | grep -A 10 "Error\|failed\|exit"
```

Common causes: a command not available in the chroot at the time the hook runs (install the package first via a package list), a path that does not exist inside the chroot (check with `chroot build/<profile>/chroot ls /path`).

### ISO boots but `/etc/os-release` has wrong values

`/etc/os-release` is generated by `base/hooks/chroot/0090-stamp-build-info.hook.chroot` at build time. If the values are wrong, the source is `brand/identity/name.env`. Do not edit `os-release` manually - it will be overwritten on the next build.

### Build produces the wrong ISO filename

ISO names are generated by `scripts/lib/iso-name.sh` from `DISTRO_ID`, `DISTRO_VERSION`, `DISTRO_EDITION`, `DISTRO_FLAVOR`, `DISTRO_ARCH`, and the build date. If the name is unexpected, check these variables in `brand/identity/name.env` and `profiles/<name>/profile.env`.

### Disk space exhausted mid-build

The build requires ~20 GB free minimum. The chroot alone is 4–8 GB depending on the edition. Clean old build directories:

```bash
sudo ./scripts/build/clean.sh shopno-os-desktop-gnome
# or manually:
sudo rm -rf build/shopno-os-desktop-gnome/
```

Build artifacts in `build/output/` are not cleaned automatically. Move or delete ISOs you no longer need.

---

## 12. What Not to Do

These mistakes are common enough to document explicitly:

**Do not run `lb build` directly.**

```bash
# Wrong - skips lint, brand loading, package injection, signing
cd build/shopno-os-desktop-gnome && lb build

# Correct
sudo ./scripts/build/build.sh shopno-os-desktop-xfce
```

Running `lb build` directly bypasses the entire orchestration layer: package lists will not be injected, brand variables will not be available to hooks, and the ISO will not be named, signed, or moved correctly.

**Do not edit files inside `build/<profile>/config/` manually.**

The contents of `build/<profile>/config/` are assembled by `prepare-lb-config.sh` and `inject-packages.sh` on every build. Any manual changes are silently wiped the next time you build. Make your changes in the source directories (`base/`, `editions/`, `flavors/`, `brand/`, `profiles/`) and let the build system assemble them.

**Do not add packages to hooks.**

```bash
# Wrong - bypasses lint and package management
apt-get install -y some-package

# Correct - add to the appropriate .list.chroot file
echo "some-package" >> editions/desktop/package-lists/shopno-os-desktop-apps.list.chroot
```

**Do not commit `build/` to git.**

The `.gitignore` excludes it. If you somehow end up with build artifacts staged, unstage them:

```bash
git rm -r --cached build/
```

**Do not use `--no-clean` after adding or removing packages.**

The cached chroot will not reflect the new package state. The resulting ISO will be inconsistent. Use a clean build whenever the package lists change.
