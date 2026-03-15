# Adding a New Flavor

> **Runbook:** How to create a new desktop experience layer in ShopnoOS.

---

## What Is a Flavor?

A flavor defines what the OS *looks and feels like*. It provides a desktop environment, display manager, DE-specific apps, theming, and per-user skeleton configuration. A flavor never adds capability packages — those belong in editions.

> **Rule:** No capability packages in `flavors/`. A flavor provides a DE shell + theming only. If a package would be useful without the DE, it belongs in an edition.

---

## The Hard Boundary: Flavor vs Edition

| Belongs in Flavor | Belongs in Edition | Belongs in Base |
|---|---|---|
| `gnome-shell`, `gdm3`, GNOME themes | `xorg`, `pipewire`, `network-manager` | `systemd`, firmware, kernel |
| `kde-plasma-desktop`, `sddm` | `cups`, `sane` (print stack) | `apparmor`, `ufw` |
| `xfce4`, `lightdm`, `xscreensaver` | `flatpak`, `gnome-software` | `bash`, `coreutils`, `curl` |
| DE-specific app replacements | Common apps (`gimp`, `vlc`, `ffmpeg`) | `grub`, `shim`, `mokutil` |
| `dconf`/gschema overrides | `pulseaudio`, `alsa-utils` | `openssh`, `openvpn` |

---

## Before You Start

- Name the DE you are packaging. The flavor directory name must match: `flavors/hyprland/`, `flavors/sway/`, etc.
- Identify which display manager this DE uses (`gdm3`, `lightdm`, `sddm`, `greetd`...).
- List DE-specific apps that replace generic ones (e.g. Dolphin replaces Nautilus in KDE).
- Decide which editions this flavor pairs with. You'll create a profile for each combination.
- Identify any `.deb` files with no APT source. Plan how to handle them before starting (see Step 4).

---

## Step-by-Step Runbook

### Step 1 — Scaffold the Directory

```bash
./scripts/dev/new-flavor.sh <flavor-name>

# Example:
./scripts/dev/new-flavor.sh hyprland
```

This creates:

```
flavors/hyprland/
├── README.md
├── package-lists/
│   └── shopno-os-flavor-hyprland.list.chroot
├── config/
│   └── includes.chroot/
│       ├── etc/
│       │   └── shopno-os/flavor                ← write 'hyprland' here
│       └── usr/
├── skel/
│   └── .config/                            ← per-user dotfiles go here
└── hooks/
    └── chroot/
```

---

### Step 2 — Write the README

Document the flavor thoroughly before writing any package lists:

- Which DE this provides and its upstream project URL
- Which display manager is used and why
- Which editions it is designed to pair with
- Any non-APT packages included and why they cannot come from APT
- Known limitations or hardware requirements

---

### Step 3 — Define Package Lists

Create package list files in `flavors/<n>/package-lists/`. Naming convention:

```
shopno-os-flavor-<n>.list.chroot           # DE core packages
shopno-os-flavor-<n>-apps.list.chroot      # DE-specific app replacements
shopno-os-display-manager.list.chroot      # display manager + screen locker
shopno-os-input.list.chroot                # input method (if locale-specific)
```

Rules for the display manager list:

- Include only the DM, its greeter, and a screen locker.
- Do **not** include a second DM if another layer already provides one — that causes conflicts.
- The display manager list is flavor-owned. It must not appear in `editions/` or `base/`.

---

### Step 4 — Handle Non-APT Packages

If you need `.deb` files that are not in any APT repository, **do not** place them directly inside `includes.chroot/`. That is an antipattern — they bypass package management and lint checks.

**Option A — Host in a local APT repo (preferred):**

Add a repo entry to `base/config/archives/`:

```
# base/config/archives/shopno-os-local.list.chroot
deb [trusted=yes] file:///srv/local-repo bookworm main
```

**Option B — Install via hook (last resort):**

```sh
#!/bin/sh
# flavors/<n>/hooks/chroot/9010-local-debs.hook.chroot
# Reason: ttf-bijoy has no APT source; vendor provides .deb only.
set -e
dpkg -i /path/to/ttf-bijoy_1.0.0-2_all.deb || apt-get -f install -y
```

Always include a comment explaining why APT is not available. This is auditable and future-proof.

---

### Step 5 — Configure Skel

Per-user default configuration goes in `flavors/<n>/skel/`. This directory is overlaid onto `/etc/skel` during the build, so every new user gets these defaults.

```
# GNOME:
flavors/gnome/skel/
└── .config/
    └── dconf/
        └── user                        ← pre-configured dconf db

# XFCE:
flavors/xfce/skel/
└── .config/
    └── xfce4/
        └── xfconf/                     ← XFCE channel XML files
```

> **Note:** Skel files are copied to new user home directories at account creation. They are **not** retroactively applied to existing users. Always test with a fresh user account.

---

### Step 6 — Write gschema Overrides (GNOME/GTK DEs)

For GNOME or GTK-based DEs, place schema overrides at:

```
flavors/<n>/config/includes.chroot/usr/share/glib-2.0/schemas/
└── shopno-os-<n>-overrides.gschema.xml
```

Example:

```xml
<?xml version='1.0' encoding='UTF-8'?>
<schemalist>
  <schema id='org.gnome.desktop.background'>
    <override name='picture-uri'>
      <default>'file:///usr/share/backgrounds/shopno-os-default.png'</default>
    </override>
  </schema>
</schemalist>
```

---

### Step 7 — Write Hooks

Hooks are numbered for controlled execution order. Common flavor hooks:

```
0010-<n>-dm-enable.hook.chroot     # enable display manager systemd unit
0020-<n>-skel-copy.hook.chroot     # copy skel if needed beyond live-build
0075-lightdm.hook.chroot           # configure autologin for live session
```

> **Rule:** Hooks must **never** install packages. Configuration, service enabling, and symlinks only.

---

### Step 8 — Create Build Profiles

Create a profile for each edition+flavor combination:

```bash
cp -r profiles/_template profiles/shopno-os-desktop-hyprland
cp -r profiles/_template profiles/shopno-os-pro-hyprland
```

```bash
# profiles/shopno-os-desktop-hyprland/profile.env
DISTRO_EDITION="desktop"
DISTRO_FLAVOR="hyprland"
DISTRO_HARDWARE="generic"
DISTRO_ARCH="amd64"
LB_DISTRIBUTION="bookworm"
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi"
LB_MEMTEST="none"
```

---

### Step 9 — Lint and Test

```bash
./scripts/dev/lint-packages.sh
./scripts/build/build.sh shopno-os-desktop-hyprland --dry-run
./scripts/build/build.sh shopno-os-desktop-hyprland
```

---

## Branding Integration

Flavors automatically inherit branding from `brand/identity/` and `brand/assets/`. Do not hardcode wallpaper paths or distribution names. The build system injects:

- Wallpaper: `brand/assets/wallpapers/base/shopno-os-default.png` (or an edition-specific variant)
- GRUB background: `brand/assets/grub/background.png`
- Plymouth logo: `brand/assets/plymouth/logo.png`

To set a flavor-specific wallpaper, add it to `brand/assets/wallpapers/` and reference it in your gschema override or skel configuration.

---

## Common Mistakes

| Mistake | What Goes Wrong | Fix |
|---|---|---|
| Placing `.deb` files in `includes.chroot/` | Bypasses package management and lint | Use a local APT repo or an annotated hook |
| Putting capability packages in the flavor | Inflates ISO size for users who don't need them | Move to `editions/<n>/package-lists/` |
| Multiple display managers in one build | `systemd` unit conflicts at boot | One DM per flavor — no exceptions |
| Skel files not tested with a fresh user | Hidden defaults, broken first-run experience | Always test with a new user account |
| Hardcoding wallpaper paths | Breaks on rebrand | Reference `brand/assets/` paths |
| Skipping `lint-packages.sh` | Duplicate packages cause live-build conflicts | Always lint before committing |

---

## Documentation Checklist

After creating the flavor, update:

- [ ] `flavors/<n>/README.md` — filled in completely (Step 2)
- [ ] `docs/adding-flavor.md` — add your flavor to the known flavors table below
- [ ] `docs/package-ownership.md` — list DE packages and their rationale
- [ ] `docs/architecture.md` — add flavor to the layer overview

---

## Known Flavors

| Flavor | Directory | Desktop Environment | Display Manager |
|--------|-----------|--------------------|-----------------| 
| gnome | `flavors/gnome/` | GNOME Shell | GDM3 |
| kde | `flavors/kde/` | KDE Plasma | SDDM |
| xfce | `flavors/xfce/` | XFCE 4 | LightDM |
| minimal-x | `flavors/minimal-x/` | Openbox / i3 | — |

*Add your flavor to this table when you create it.*
