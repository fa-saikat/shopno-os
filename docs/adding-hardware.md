# Adding a Hardware Layer

> **Runbook:** How to create a hardware-specific overlay in ShopnoOS.

---

## What Is a Hardware Layer?

Hardware layers are optional overlays that add hardware-specific packages and configuration on top of any edition+flavor combination. They are selected at profile build time and are never baked into `base/`, `editions/`, or `flavors/`.

> **Critical:** NVIDIA drivers must **never** appear in `base/` or any edition. GPU drivers live exclusively in `hardware/nvidia/`. Baking drivers into a shared layer installs them on incompatible hardware and is not fixable without a full rebuild.

---

## Hardware Layer vs Other Layers

| Goes in `hardware/<vendor>/` | Goes in `base/` | Never in `hardware/` |
|---|---|---|
| NVIDIA proprietary drivers | `linux-firmware` (generic) | DE packages |
| AMD ROCm userspace stack | `firmware-linux-nonfree` | Edition packages |
| `open-vm-tools` (VMware) | `firmware-amd-graphics` (base blob) | Flavor packages |
| `virtualbox-guest-additions` | `bluez`, `bluetooth` (core stack) | Brand assets |
| RPi-specific kernel/firmware | `iw`, `wireless-tools` | Build scripts |

---

## Existing Hardware Layers

| Layer | Directory | Purpose |
|-------|-----------|---------|
| `nvidia` | `hardware/nvidia/` | NVIDIA proprietary driver + optional CUDA |
| `amd` | `hardware/amd/` | AMD ROCm userspace stack |
| `vm` | `hardware/vm/` | VM guest tools (VMware, VirtualBox, QEMU) |
| `rpi` | `hardware/rpi/` | Raspberry Pi / ARM board support (future) |

---

## Step-by-Step Runbook

### Step 1 — Create the Directory

There is no scaffold script for hardware layers yet. Create the structure manually:

```bash
mkdir -p hardware/<vendor>/package-lists
mkdir -p hardware/<vendor>/hooks/chroot
touch hardware/<vendor>/README.md
```

Example for a new Intel Arc GPU layer:

```
hardware/arc/
├── README.md
├── package-lists/
│   └── shopno-os-hw-arc.list.chroot
└── hooks/
    └── chroot/
        └── 0010-arc-setup.hook.chroot
```

---

### Step 2 — Write the README

Document exactly:

- Which hardware this layer targets (PCI IDs if known)
- Which packages it installs and why
- Any conflicts with other hardware layers (e.g. `arc` + `nvidia` conflict)
- How to verify the layer is working after boot
- Upstream driver source and version tracking

---

### Step 3 — Define the Package List

Name the file `shopno-os-hw-<vendor>.list.chroot`. Include a comment block explaining the source:

```
# shopno-os-hw-arc.list.chroot
# Intel Arc GPU userspace stack
# Source: https://dgpu-docs.intel.com/
# Last reviewed: 2025-01

intel-media-va-driver-non-free
libigdgmm12
libvpl2
vainfo
```

If the hardware layer requires a non-standard APT repository, add it to `base/config/archives/` with a `.list.chroot` and `.key.chroot` file. Do not hardcode repo URLs inside hooks.

---

### Step 4 — Write the Setup Hook

The hook handles module loading, initramfs updates, and service configuration. It must not install packages.

```sh
#!/bin/sh
# 0010-arc-setup.hook.chroot
# Configure Intel Arc driver post-install
set -e

# Ensure i915 loads early
echo 'i915' >> /etc/modules

# Rebuild initramfs to include firmware
update-initramfs -u -k all

echo '[arc] Intel Arc setup complete'
```

> **Rule:** Hooks must **never** install packages. Configuration, `modprobe`, service enabling, and `update-initramfs` only.

---

### Step 5 — Register in a Profile

To use the hardware layer, set `DISTRO_HARDWARE` in the profile:

```bash
# profiles/shopno-os-desktop-gnome-arc/profile.env
DISTRO_EDITION="desktop"
DISTRO_FLAVOR="gnome"
DISTRO_HARDWARE="arc"
DISTRO_ARCH="amd64"
LB_DISTRIBUTION="bookworm"
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi"
LB_MEMTEST="none"
```

The build system automatically symlinks `hardware/arc/package-lists/*` into the live-build config tree and merges `hardware/arc/config/includes.chroot/` as the final overlay.

---

### Step 6 — Lint and Verify

```bash
./scripts/dev/lint-packages.sh
./scripts/build/build.sh shopno-os-desktop-gnome-arc --dry-run
```

---

## Config Merge Order

Hardware is applied last and wins over all other layers:

| Order | Layer | Can Override |
|-------|-------|-------------|
| 1 (first) | `base/config/includes.chroot/` | Nothing — it is the foundation |
| 2 | `editions/<n>/config/includes.chroot/` | Base files |
| 3 | `flavors/<n>/config/includes.chroot/` | Base and edition files |
| 4 (last) | `hardware/<vendor>/config/includes.chroot/` | All previous layers |

A hardware layer can override any config file from base, editions, or flavors — including module configs, udev rules, and GRUB parameters. Use this carefully and document any overrides explicitly in the README.

---

## NVIDIA Layer — Special Rules

The NVIDIA layer has additional constraints:

- Never add `nvidia-driver` to any other layer under any circumstances.
- `dkms` belongs in `base/shopno-os-hardware.list.chroot`, not here — it serves all kernel modules, not just NVIDIA.
- CUDA is optional. Add a separate `shopno-os-hw-nvidia-cuda.list.chroot` if needed rather than bundling it into the base NVIDIA list.
- The nouveau blacklist belongs in the hook, not in `includes.chroot/`, to ensure it applies across all installed kernel versions.

```sh
#!/bin/sh
# 0010-nvidia-setup.hook.chroot
set -e

# Blacklist nouveau
cat >> /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

update-initramfs -u -k all
echo '[nvidia] Setup complete — nouveau blacklisted'
```

---

## VM Layer

The `vm` hardware layer builds ISOs intended for virtual machine testing. It installs guest tools for the three major hypervisors:

- `open-vm-tools` — VMware Workstation / ESXi
- `virtualbox-guest-utils` — VirtualBox
- `qemu-guest-agent` — QEMU/KVM

The profile `shopno-os-desktop-gnome` + `DISTRO_HARDWARE=vm` produces the primary testing ISO used in CI smoke tests.

---

## Common Mistakes

| Mistake | What Goes Wrong | Fix |
|---|---|---|
| Adding GPU drivers to `base/` | Installs on incompatible hardware; breaks non-GPU builds | GPU drivers in `hardware/<vendor>/` only |
| Hardcoding repo URLs in hooks | Repo changes break the hook silently | Add repo to `base/config/archives/` |
| Installing packages in hooks | Bypasses lint; causes silent conflicts | Move to `.list.chroot` files |
| Not blacklisting conflicting modules | Old and new drivers conflict at boot | Use `modprobe.d` in the hook |
| Forgetting `update-initramfs` | Driver not loaded at boot | Always run it at end of setup hook |

---

## Documentation Checklist

After creating the hardware layer, update:

- [ ] `hardware/<vendor>/README.md` — filled in completely (Step 2)
- [ ] `docs/adding-hardware.md` — add your layer to the known hardware table above
- [ ] `docs/package-ownership.md` — list hardware packages and their rationale
- [ ] `docs/architecture.md` — add the layer to the hardware section
