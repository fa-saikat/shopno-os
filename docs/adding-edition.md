# Adding a New Edition

> **Runbook:** How to create a new capability layer in ShopnoOS.

---

## What Is an Edition?

An edition defines what the OS *does* - its capability layer. Editions add packages and configuration that give the system a purpose: desktop infrastructure, development tooling, server roles, etc. They sit between the base layer (what the OS *is*) and the flavor layer (what the OS *looks like*).

| Layer | Controls | Example Packages |
|-------|----------|-----------------|
| `base/` | OS fundamentals - shared by everything | systemd, firmware, kernel, ufw |
| `editions/<n>/` | Capability: what the OS does | xorg, pipewire, NetworkManager, docker |
| `flavors/<n>/` | Experience: what the OS looks/feels like | gnome-shell, kde-plasma, xfce4 |

> **Golden Rule:** A package lives in exactly ONE place. If you find yourself copying a package list - you're doing it wrong.

---

## Before You Start

Ask these questions before scaffolding:

- Does this edition overlap with `desktop/` or `pro/`? If so, consider extending those instead.
- What capability packages uniquely define this edition? Write them down first.
- Which flavors will this edition pair with? You'll need a profile for each combination.
- Does it need hardware-specific packages (e.g. GPU drivers)? Those go in `hardware/`, not here.

---

## Step-by-Step Runbook

### Step 1 - Scaffold the Directory

```bash
./scripts/dev/new-edition.sh <edition-name>

# Example:
./scripts/dev/new-edition.sh gaming
```

This creates the following structure:

```
editions/gaming/
├── README.md
├── package-lists/
│   └── shopno-os-gaming.list.chroot        ← start here
├── config/
│   └── includes.chroot/
│       └── etc/
│           └── shopno-os/
│               └── edition             ← write your edition name here
├── skel/                               ← optional capability dotfiles (e.g. .config/antimicrox/), merged into /etc/skel before flavor skel; keep paths disjoint from flavor skel
│   └── .config/
└── hooks/
    └── chroot/
```

---

### Step 2 - Write the README

`README.md` is mandatory. Fill in:

- What this edition **IS** - one paragraph, be specific.
- What this edition is **NOT** - explicitly state what stays in `base/` or `flavors/`.
- Which flavors it is designed to pair with.
- Any special build requirements or dependencies on other layers.

---

### Step 3 - Define Package Lists

Create package list files in `editions/<n>/package-lists/`. Each file must:

- Be named `shopno-os-<edition>-<purpose>.list.chroot`
- Contain one package per line
- Have a comment block at the top explaining its purpose

Example layout for the gaming edition:

```
package-lists/
├── shopno-os-gaming.list.chroot           # core gaming packages
├── shopno-os-gaming-audio.list.chroot     # low-latency audio stack
└── shopno-os-gaming-vulkan.list.chroot    # Vulkan/OpenGL userspace (generic)
```

> **Note:** GPU-specific drivers (NVIDIA/AMD) do **not** go here. They belong in `hardware/nvidia/` or `hardware/amd/` and are selected at profile build time.

---

### Step 4 - Write the Edition Marker

The file `editions/<n>/config/includes.chroot/etc/shopno-os/edition` must contain exactly one line - the edition name:

```
gaming
```

This allows the live system to identify its edition at runtime.

---

### Step 5 - Add Hooks (if needed)

Hooks go in `editions/<n>/hooks/chroot/` and are numbered to control execution order. Files must end in `.hook.chroot`.

```
0010-gaming-services.hook.chroot    # runs early
0050-gaming-groups.hook.chroot      # runs mid-build
0090-gaming-cleanup.hook.chroot     # runs late
```

> **Rule:** Hooks must **never** install packages with `apt-get` or `dpkg`. All packages must be declared in `package-lists/` files. Hooks are for configuration, symlinks, and service enabling only.

---

### Step 6 - Create Build Profiles

Every valid edition+flavor combination needs a profile:

```bash
cp -r profiles/_template profiles/shopno-os-gaming-gnome
```

```bash
# profiles/shopno-os-gaming-gnome/profile.env
DISTRO_EDITION="gaming"
DISTRO_FLAVOR="gnome"
DISTRO_HARDWARE="generic"
DISTRO_ARCH="amd64"
LB_DISTRIBUTION="bookworm"
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi"
LB_MEMTEST="none"
```

---

### Step 7 - Lint and Validate

```bash
# Check for duplicate packages across all layers:
./scripts/dev/lint-packages.sh

# Compare your new edition against desktop/:
./scripts/dev/diff-editions.sh desktop gaming
```

Fix all lint errors before committing. Duplicate packages across layers cause live-build conflicts and are enforced as errors.

---

### Step 8 - Test Build

```bash
# Dry run to verify config assembly:
./scripts/build/build.sh shopno-os-gaming-gnome --dry-run

# Full build:
./scripts/build/build.sh shopno-os-gaming-gnome
```

---

## Package Ownership Checklist

Before finalizing your package lists, verify each package belongs in this edition:

| Package Type | Correct Layer | Never In |
|---|---|---|
| Kernel, firmware, systemd | `base/package-lists/` | This edition - ever |
| AppArmor, ufw, auditd | `base/package-lists/` | This edition |
| Xorg, PipeWire, NetworkManager | `editions/desktop/` | Here (unless your edition explicitly extends desktop) |
| DE shells (GNOME, KDE, XFCE) | `flavors/<n>/` | Here - ever |
| GPU drivers (NVIDIA, AMD) | `hardware/<vendor>/` | Here - ever |
| Your new capability packages | `editions/<n>/` | Anywhere else |

---

## Common Mistakes

| Mistake | What Goes Wrong | Fix |
|---|---|---|
| Installing packages in hooks | Packages bypass lint and may conflict | Move all packages to `.list.chroot` files |
| Putting DE packages in the edition | DE is the flavor's job - causes double-install | Move to `flavors/<de>/package-lists/` |
| Hardcoding brand names in configs | Breaks the rebrand pipeline | Use `${DISTRO_NAME}` from `brand/identity/` |
| Skipping `lint-packages.sh` | Duplicate packages cause live-build conflicts | Always lint before committing |
| No README | Future contributors don't know what this edition is | Write the README in Step 2 - not after |

---

## Documentation Checklist

After creating the edition, update:

- [ ] `editions/<n>/README.md` - filled in completely (Step 2)
- [ ] `docs/adding-edition.md` - add your edition to the known editions table below
- [ ] `docs/package-ownership.md` - list which packages live in your edition and why
- [ ] `docs/architecture.md` - add the edition to the layer overview

---

## Known Editions

| Edition | Directory | Purpose |
|---------|-----------|---------|
| core | `editions/core/` | Minimal CLI / server / container base |
| desktop | `editions/desktop/` | General-purpose GUI (no DE - that's a flavor) |
| pro | `editions/pro/` | Developer / power-user workstation |
| edu | `editions/edu/` | Education-focused (future) |

*Add your edition to this table when you create it.*
