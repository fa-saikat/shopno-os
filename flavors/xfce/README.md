# flavors/xfce — XFCE Desktop Flavor

> **Layer:** Flavor (Experience)
> **Role:** Desktop environment shell, display manager, and XFCE-specific tooling
> **Inherits from:** `base/` + an edition (typically `desktop/`)

---

## What This Flavor Is

The `xfce` flavor provides the **XFCE desktop environment** on top of whichever edition it is composed with. It is responsible for exactly one concern: *what the OS looks and feels like.*

This flavor includes:

- XFCE4 shell and all first-party panel plugins
- LightDM display manager with session configuration
- Thunar file manager and its plugin ecosystem
- IBus input method stack for multilingual input (Bengali/Avro support)
- A curated skel structure for per-user defaults
- Hooks to configure the display manager and session on first boot

This flavor does **not** include, and must never include:

- Applications that belong to the edition layer (browsers, office, media players, development tools)
- Fonts that are not XFCE-specific (those live in `editions/desktop/package-lists/shopno-os-fonts.list.chroot`)
- Hardware drivers or firmware
- Anything from `base/` that is already guaranteed to be present

---

## Directory Structure

```
flavors/xfce/
├── package-lists/
│   ├── shopno-os-xfce.list.chroot           # XFCE4 shell + all panel plugins + Thunar
│   ├── shopno-os-display-manager.list.chroot # LightDM + screen locker
│   └── shopno-os-input.list.chroot          # IBus + Avro + input utilities
├── config/
│   └── includes.chroot/
│       ├── etc/                         # Config overlaid into /etc at build time
│       ├── usr/                         # Shared assets under /usr/share
│       ├── NeoHtop_1.2.0_x86_64.deb    # ⚠ See: Local .deb Files note below
│       ├── printer-driver-xprinter_3.13.3_all.deb
│       └── ttf-bijoy_1.0.0-2_all.deb
├── hooks/
│   └── chroot/
│       └── 9075-lightdm.hook.chroot     # Enables and configures LightDM
├── skel/                                # Copied to /etc/skel — user defaults
│   └── .config/
│       └── (XFCE per-user config files)
└── README.md
```

---

## Package Lists

### `shopno-os-xfce.list.chroot` — XFCE Core

The full XFCE4 shell plus the complete suite of panel plugins and supporting applications. Key packages:

| Package | Purpose |
|---|---|
| `xfce4` | Meta-package: XFCE shell, panel, desktop, settings |
| `xfce4-terminal` | Default terminal emulator |
| `thunar` | File manager |
| `thunar-archive-plugin` | Archive context menu integration |
| `thunar-volman` | Removable device automount |
| `ristretto` | Lightweight image viewer |
| `mousepad` | Lightweight text editor |
| `xfce4-notifyd` | Notification daemon |
| `xfce4-power-manager` | Battery and power management |
| `xfce4-screenshooter` | Screenshot tool |
| `xfce4-whiskermenu-plugin` | Application menu |
| `tumbler` | Thumbnail service for Thunar |
| `xfce4-panel-profiles` | Panel layout import/export |

All standard XFCE panel plugins are included (`cpugraph`, `netload`, `weather`, `datetime`, `sensors`, `systemload`, etc.) to give users a complete panel configuration experience without requiring post-install package hunting.

### `shopno-os-display-manager.list.chroot` — LightDM

| Package | Purpose |
|---|---|
| `lightdm` | Display manager and greeter |
| `light-locker` | Screen locker integrated with LightDM |
| `xscreensaver` | Screensaver daemon and collection |

LightDM is configured via `hooks/chroot/9075-lightdm.hook.chroot`. The hook enables the `lightdm` service, sets the default session to `xfce`, and applies any greeter customizations sourced from `brand/assets/`.

### `shopno-os-input.list.chroot` — Input Methods

Provides full IBus support with the Avro phonetic input method for Bengali script:

| Package | Purpose |
|---|---|
| `ibus` | Input method framework daemon |
| `ibus-avro` | Avro phonetic keyboard for Bengali |
| `ibus-gtk` / `ibus-gtk3` | GTK integration for IBus |
| `gir1.2-ibus-1.0` | GObject introspection bindings |
| `libibus-1.0-5` | IBus shared library |
| `python3-ibus-1.0` | Python bindings |
| `xcape` | Key remapping for input workflows |
| `xclip` | Clipboard utility (used by input scripts) |
| `dconf-cli` | Apply dconf settings from hooks/skel |

> **Note on `ibus-data`:** This package appears twice in the source list. Deduplicate before committing — `apt` will not error on duplicates but `lint-packages.sh` will flag them.

---

## Hooks

### `9075-lightdm.hook.chroot`

Runs during the chroot stage after all packages are installed. Responsibilities:

- Enables `lightdm` as the default display manager (`systemctl enable lightdm`)
- Writes `/etc/lightdm/lightdm.conf` with the correct `user-session=xfce` directive
- Optionally sets a custom greeter background sourced from `brand/assets/wallpapers/base/`
- Configures `light-locker` integration

Hook numbering convention: `9075` places this after edition-level hooks (`9030`–`9050`) and before the final cleanup hook (`9999`). Do not renumber without checking for ordering conflicts with other hooks.

---

## Skel

Files placed in `flavors/xfce/skel/` are overlaid into `/etc/skel/` during the build and therefore copied into every new user's home directory on first login.

This is the correct place for:

- Default XFCE panel layout (via `xfce4/xfconf/` settings)
- Default Thunar bookmarks (`gtk-3.0/bookmarks` — shared with `brand/skel-branding/`)
- IBus autostart configuration
- Default terminal color scheme and profile

**Do not place** large binary files, wallpapers, or anything that would bloat every user's home directory. Wallpapers are referenced by path under `/usr/share/`, not copied into skel.

---

## Local `.deb` Files in `config/includes.chroot/`

The current tree contains three `.deb` files placed directly inside `config/includes.chroot/`:

| File | Description |
|---|---|
| `NeoHtop_1.2.0_x86_64.deb` | NeoHtop system monitor (not in Debian repos) |
| `printer-driver-xprinter_3.13.3_all.deb` | Xprinter label printer driver |
| `ttf-bijoy_1.0.0-2_all.deb` | Bijoy Bengali font (proprietary distribution) |

**⚠ This is a known antipattern.** Per the architecture's Package Ownership Rules, packages must not live in `includes.chroot/` — they belong in `package-lists/` and are installed via `apt`.

The preferred resolution for each file:

1. **Host in a local APT repo** and reference it via `base/config/archives/`. This is the correct, reproducible approach.
2. **Install via a dedicated hook** using `dpkg -i` as a last resort, with an inline comment explaining why a repo is not available. The hook should verify the `.deb` checksum before installing.

Until resolved, these `.deb` files will not be caught by `lint-packages.sh` and could produce inconsistent behavior across clean and cached builds. Tracking issue should be filed.

---

## Profiles That Use This Flavor

| Profile | Edition | Notes |
|---|---|---|
| `shopno-os-desktop-xfce` | `desktop` | Standard user workstation |

To create a new profile using this flavor, copy `profiles/_template/` and set:

```bash
# profiles/shopno-os-<edition>-xfce/profile.env
DISTRO_EDITION="<edition>"
DISTRO_FLAVOR="xfce"
```

---

## Adding Packages to This Flavor

1. Determine which list the package belongs in (`xfce`, `display-manager`, or `input`).
2. Add the package name to the appropriate `.list.chroot` file — one package per line.
3. Run the lint check from the repo root:
   ```bash
   ./scripts/dev/lint-packages.sh
   ```
4. If the linter reports a duplicate, the package already exists in `base/` or the target edition. Remove it from this flavor — do not fight the linter.
5. Build and verify:
   ```bash
   ./scripts/build/build.sh shopno-os-desktop-xfce --dry-run
   ```

---

## What Does NOT Belong Here

The following are common mistakes — all are caught by `lint-packages.sh` but worth knowing upfront:

| Package | Correct location |
|---|---|
| `xorg`, `xserver-xorg-*` | `editions/desktop/package-lists/shopno-os-desktop.list.chroot` |
| `vlc`, `mpv`, `ffmpeg` | `editions/desktop/package-lists/shopno-os-desktop-multimedia.list.chroot` |
| `fonts-noto-*` | `editions/desktop/package-lists/shopno-os-fonts.list.chroot` |
| `gimp`, `inkscape`, `geany` | `editions/desktop/package-lists/shopno-os-desktop-apps.list.chroot` |
| `cups`, `cups-filters` | `editions/desktop/package-lists/shopno-os-desktop-print.list.chroot` |
| `nvidia-driver`, `firmware-*` | `base/` or `hardware/nvidia/` |
| `build-essential`, `git`, `docker` | `editions/pro/package-lists/` |
| `blueman` | `flavors/xfce/package-lists/` ← this is actually correct; it's the GUI bluetooth manager |

---

## Relationship to Brand Assets

This flavor references but does not own branding. Wallpapers, colors, and logos come from `brand/`:

- **Default wallpaper:** resolved via `brand_wallpaper_base()` → `brand/assets/wallpapers/base/shopno-os-default.png`
- **Edition wallpaper:** `brand/assets/wallpapers/editions/desktop/` (set by the `desktop` edition layer)
- **GTK theme:** set via `skel/.config/xfce4/xfconf/` — theme name references packages installed by the edition layer

To change the wallpaper for this flavor without touching brand assets, place an override in `config/includes.chroot/usr/share/backgrounds/xfce/`.

---

## Known Issues and TODOs

- [ ] Resolve the three `.deb` files in `includes.chroot/` — move to local APT repo or dedicated hook
- [ ] Deduplicate `ibus-data` entry in `shopno-os-input.list.chroot`
- [ ] Add `lightdm-settings` once the malformed `lightdm-settingsflatpak` entry is corrected in the source list
- [ ] Add `blueman` to `shopno-os-xfce.list.chroot` once bluetooth layer placement is confirmed (see `packages-categorized.md`)
- [ ] Document skel contents once they are finalized

---

*This flavor owns the experience layer only. If a package makes the system capable of something new, it belongs in an edition. If it makes the system look or feel different, it belongs here.*
