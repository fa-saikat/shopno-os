# Package Ownership

> Which packages live where, why, and what happens when they end up in the wrong place.

---

## The Rule

A package lives in exactly one place. If the same package name appears in two different layers' `.list.chroot` files, `lint-packages.sh` fails the build. This is not a style preference — duplicate packages across layers cause live-build conflicts that are time-consuming to debug and produce broken ISOs.

When you are placing a new package and are unsure where it belongs, work through the decision tree below before touching any file.

---

## Decision Tree

```
Is this package needed on every ISO, regardless of edition or DE?
├── YES → base/
│         └── Is it kernel/firmware/boot infrastructure? → shopno-os-hardware.list.chroot
│             Is it a security tool?                     → shopno-os-security.list.chroot
│             Is it a core CLI utility?                  → shopno-os-utils.list.chroot
│             Is it OS plumbing (systemd, grub, cryptsetup)? → shopno-os-base.list.chroot
│
└── NO  → Does it provide desktop infrastructure (Xorg, audio, networking GUI)?
          ├── YES → editions/desktop/package-lists/
          │
          └── NO  → Is it a development or virtualisation tool?
                    ├── YES → editions/pro/package-lists/
                    │
                    └── NO  → Is it a desktop environment shell, display manager,
                               or DE-specific application?
                              ├── YES → flavors/<de>/package-lists/
                              │
                              └── NO  → Is it hardware-specific (GPU driver,
                                         hypervisor guest tool, board support)?
                                        ├── YES → hardware/<vendor>/package-lists/
                                        │
                                        └── NO  → Re-read the question. If still
                                                   unclear, open a discussion before
                                                   adding to any layer.
```

---

## Layer-by-Layer Reference

### `base/` — Shared by Every ISO

Every package here installs on every ISO regardless of edition, flavor, or hardware. The bar for inclusion is high: if a package is not needed on a headless `core` server ISO, it does not belong here.

#### `shopno-os-base.list.chroot` — OS Plumbing

Boot infrastructure, init system, core system daemons, and the absolute minimum required to have a bootable Debian system.

```
accountsservice         cryptsetup              grub-common
bash-completion         cryptsetup-initramfs    grub-efi-amd64
bc                      dbus-user-session       grub-efi-amd64-bin
debconf                 dbus-x11                grub-efi-amd64-signed
dialog                  dirmngr                 grub-efi-ia32-bin
haveged                 grub-pc                 grub-pc-bin
less                    grub2-common            lsb-release
mokutil                 mtools                  os-prober
perl                    shim-helpers-amd64-signed
shim-signed             shim-signed-common      shim-unsigned
sudo                    systemd-sysv            systemd-timesyncd
```

#### `shopno-os-hardware.list.chroot` — Kernel and Firmware

The kernel, all firmware blobs, and tools required for hardware support across the full range of target machines. Includes `dkms` because it is needed by any kernel module build — not just NVIDIA.

```
atmel-firmware          dkms                    firmware-amd-graphics
firmware-atheros        firmware-bnx2           firmware-bnx2x
firmware-brcm80211      firmware-cavium         firmware-intel-sound
firmware-iwlwifi        firmware-libertas       firmware-linux
firmware-linux-free     firmware-linux-nonfree  firmware-misc-nonfree
firmware-myricom        firmware-netronome      firmware-netxen
firmware-qcom-media     firmware-qcom-soc       firmware-qlogic
firmware-realtek        firmware-samsung        firmware-siano
firmware-sof-signed     firmware-ti-connectivity firmware-zd1211
intel-media-va-driver   iw                      linux-headers-amd64
module-assistant
```

Bluetooth sits here at the kernel/firmware level:

```
bluetooth               bluez                   bluez-firmware
```

> **Note:** `firmware-amd-graphics` is the generic open-source firmware blob, present in base. The proprietary AMD ROCm userspace stack lives in `hardware/amd/` — not here.

#### `shopno-os-security.list.chroot` — Security Baseline

Mandatory security tools deployed on every ISO. AppArmor and ufw are enforced on all editions — including `core`.

```
apparmor                auditd                  libefiboot1
libefivar1              openconnect             openssh-client
openssh-server          openvpn                 openvpn-systemd-resolved
ufw
```

#### `shopno-os-utils.list.chroot` — Core CLI Utilities

Filesystem tools, network utilities, and general-purpose CLI tools needed on any system regardless of whether it has a desktop.

```
apt-transport-https     btrfs-progs             curl
exfatprogs              fuse3                   git
htop                    iftop                   inxi
jfsutils                jq                      lshw
netcat-openbsd          ntfs-3g                 p7zip-full
pciutils                samba-common-bin        testdisk
udisks2                 unzip                   upower
vim                     wget                    xfsprogs
zip                     zstd
```

---

### `editions/desktop/` — General-Purpose GUI Edition

Everything needed to run a graphical desktop — display server, audio, networking applet, common applications, print stack, multimedia codecs, and fonts. There is **no desktop environment here** — that is the flavor's job.

#### `shopno-os-desktop.list.chroot` — Desktop Infrastructure

```
efibootmgr              gvfs-backends           gvfs-fuse
im-config               isolinux                libnss-mdns
libsmbclient            network-manager-gnome
network-manager-openconnect-gnome
network-manager-openvpn-gnome
pulseaudio              pulseaudio-module-bluetooth
squashfs-tools          syslinux                syslinux-common
xdg-utils               xorg                    xorriso
xserver-xorg-input-all  xserver-xorg-video-all
```

Bluetooth GUI tooling lives here (the core stack is in base):

```
bluez-tools
```

Live system packages also belong here:

```
live-boot               live-config             live-config-systemd
```

#### `shopno-os-calamares.list.chroot` — Installer

```
calamares               calamares-settings-debian
libqt5opengl5           qt5-style-kvantum
```

#### `shopno-os-desktop-apps.list.chroot` — Common Desktop Applications

Applications useful on any desktop regardless of DE. If an application has a DE-specific variant (e.g. a KDE or GNOME native version), that variant goes in the flavor, not here.

```
evince                  flatpak                 galculator
gdebi                   geany                   gimp
gnome-disk-utility      gnome-nettool           gnome-software
gnome-software-plugin-flatpak  gnome-system-tools  gparted
google-chrome-stable    hardinfo                inkscape
menu                    mpg321                  mugshot
simple-scan             timeshift               yad
zenity
```

> `google-chrome-stable` requires the Google APT repository to be added to `base/config/archives/`. It cannot be installed from Debian mirrors.

#### `shopno-os-desktop-print.list.chroot` — Print and Scan Stack

```
cups                    cups-filters            foomatic-db
foomatic-db-engine      ghostscript             printer-driver-all
printer-driver-gutenprint  system-config-printer
```

#### `shopno-os-desktop-multimedia.list.chroot` — Multimedia Codecs and Tools

```
alsa-utils              cdrdao                  cdrskin
cdtool                  dvdauthor               faad
ffmpeg                  flac                    frei0r-plugins
gstreamer1.0-plugins-bad  gstreamer1.0-plugins-good
gstreamer1.0-plugins-ugly  lame                 libxvidcore4
mjpegtools              mpv                     pavucontrol
sox                     streamripper            vlc
x264                    x265                    xarchiver
```

#### `shopno-os-fonts.list.chroot` — Fonts

```
fonts-beng              fonts-noto-color-emoji  fonts-noto-core
fonts-noto-extra        fonts-noto-ui-core      fonts-noto-ui-extra
mythes-en-us
```

#### `shopno-os-appearance.list.chroot` — Shared Theming

Cross-DE theme packages that are not tied to any specific desktop environment:

```
breeze-gtk-theme        breeze-icon-theme
```

---

### `editions/pro/` — Developer / Power-User Workstation

Packages that make sense on a developer workstation but not on a standard desktop. The `pro` edition is built on top of `desktop` via the profile system — it does not duplicate desktop packages.

#### `shopno-os-pro-dev.list.chroot` — Build Tooling and IDEs

```
autoconf                automake                build-essential
codeblocks              debhelper               dh-autoreconf
fakeroot                live-build
```

#### `shopno-os-pro-virt.list.chroot` — Virtualisation

```
kvm                     libvirt-daemon-system   qemu-kvm
virt-manager            virt-viewer
```

---

### `flavors/xfce/` — XFCE Desktop Environment

The complete XFCE experience: the DE shell, display manager, screen locker, panel plugins, XFCE-native apps, and the input method stack for Bengali locale support.

#### `shopno-os-xfce.list.chroot` — XFCE Core and Plugins

```
mousepad                ristretto               thunar
thunar-archive-plugin   thunar-data             thunar-font-manager
thunar-media-tags-plugin  thunar-volman         tumbler
xfce4                   xfce4-battery-plugin    xfce4-clipman-plugin
xfce4-cpufreq-plugin    xfce4-cpugraph-plugin   xfce4-datetime-plugin
xfce4-diskperf-plugin   xfce4-fsguard-plugin    xfce4-genmon-plugin
xfce4-mailwatch-plugin  xfce4-netload-plugin    xfce4-notifyd
xfce4-panel-profiles    xfce4-places-plugin     xfce4-power-manager
xfce4-screenshooter     xfce4-sensors-plugin    xfce4-smartbookmark-plugin
xfce4-systemload-plugin xfce4-terminal          xfce4-timer-plugin
xfce4-wavelan-plugin    xfce4-weather-plugin    xfce4-whiskermenu-plugin
xfce4-xkb-plugin
```

Bluetooth GUI frontend (the core stack is in base, CLI tools are in desktop):

```
blueman
```

#### `shopno-os-display-manager.list.chroot` — LightDM

```
light-locker            lightdm                 lightdm-settings
xscreensaver
```

#### `shopno-os-input.list.chroot` — Input Method

IBus with Avro for Bengali input support. Includes the supporting libraries and X utilities needed for IBus to function correctly under XFCE:

```
dconf-cli               gir1.2-ibus-1.0         ibus
ibus-avro               ibus-data               ibus-gtk
ibus-gtk3               libibus-1.0-5           python3-ibus-1.0
xcape                   xclip
```

---

### `hardware/nvidia/` — NVIDIA Proprietary Drivers

```
nvidia-driver           nvidia-settings
```

Optional CUDA packages in a separate list so they can be included or excluded per profile without touching the base NVIDIA list:

```
# shopno-os-hw-nvidia-cuda.list.chroot
cuda-toolkit
```

> `dkms` is **not** listed here. It is in `base/shopno-os-hardware.list.chroot` because it serves all kernel module builds, not just NVIDIA.

---

### `hardware/amd/` — AMD ROCm

```
# shopno-os-hw-amd.list.chroot
rocm-opencl-runtime     rocm-hip-runtime
```

---

### `hardware/vm/` — Virtual Machine Guest Tools

```
# shopno-os-hw-vm.list.chroot
cifs-utils              open-vm-tools           qemu-guest-agent
virtualbox-guest-utils
```

---

## Packages Requiring Special Handling

These packages have conditions or dependencies that are not obvious from the package name alone.

### Packages Requiring a Non-Standard APT Repository

| Package | Repository | Where to Add |
|---------|-----------|-------------|
| `google-chrome-stable` | Google's APT repo | `base/config/archives/google-chrome.list.chroot` + key |
| `nvidia-driver` | `non-free` component | Enable in `base/config/archives/` or use `contrib non-free` in `lb_config.sh` |
| Any `shopno-os-*` package | Internal/custom repo | `base/config/archives/` — verify package names and rename to `shopno-os-*` |
| `jadupc-remote-support-console` | Verify origin | Confirm APT source before adding to any layer |

### Packages Not Yet Placed

These packages are required by the architecture or by existing tools but are not yet in any package list. They need to be added to their correct layer:

| Package | Correct Layer | Reason |
|---------|-------------|--------|
| `apparmor` | `base/shopno-os-security.list.chroot` | Architecture spec requires it; currently missing |
| `ufw` | `base/shopno-os-security.list.chroot` | Architecture spec requires it; currently missing |
| `auditd` | `base/shopno-os-security.list.chroot` | Security baseline — add alongside apparmor/ufw |
| `live-boot` | `editions/desktop/shopno-os-desktop.list.chroot` | Required for live session |
| `live-config` | `editions/desktop/shopno-os-desktop.list.chroot` | Required for live session |
| `live-config-systemd` | `editions/desktop/shopno-os-desktop.list.chroot` | Required for live session |
| `systemd-sysv` | `base/shopno-os-base.list.chroot` | Provides `init` symlink |
| `calamares` | `editions/desktop/shopno-os-calamares.list.chroot` | Installer — desktop only |
| `python3-psutil` | `editions/desktop/` | Required by system monitor applications |
| `libqt5opengl5` | `editions/desktop/shopno-os-calamares.list.chroot` | Qt dependency for Calamares |
| `libxcb-xtest0` | `editions/desktop/` or `flavors/xfce/` | Determine which component needs it first |
| `libxvidcore4` | `editions/desktop/shopno-os-desktop-multimedia.list.chroot` | Codec — belongs with other multimedia |

### Packages with Naming Issues to Resolve

These were found as malformed concatenated entries in the original package list. They must be split and placed correctly before the next build:

| Malformed Entry | Splits Into | Correct Layer |
|----------------|------------|--------------|
| `firmware-zd1211efibootmgr` | `firmware-zd1211` + `efibootmgr` | both → `base/shopno-os-hardware` |
| `ibus-avrogoogle-chrome-stable` | `ibus-avro` + `google-chrome-stable` | `ibus-avro` → `flavors/xfce/shopno-os-input`, `google-chrome-stable` → `editions/desktop/shopno-os-desktop-apps` |
| `lightdm-settingsflatpak` | `lightdm-settings` + `flatpak` | `lightdm-settings` → `flavors/xfce/shopno-os-display-manager`, `flatpak` → `editions/desktop/shopno-os-desktop-apps` |
| `qt5-style-kvantumcalamares` | `qt5-style-kvantum` + `calamares` | both → `editions/desktop/shopno-os-calamares` |
| `live-bootlive-configlive-config-systemdsystemd-sysvmpv` | `live-boot` + `live-config` + `live-config-systemd` + `systemd-sysv` + `mpv` | first three → `editions/desktop/`, `systemd-sysv` → `base/`, `mpv` → `editions/desktop/shopno-os-desktop-multimedia` |
| `system-config-printerevince` | `system-config-printer` + `evince` | both → `editions/desktop/shopno-os-desktop-print` / `shopno-os-desktop-apps` |
| `vlccups` | `vlc` + `cups` | `vlc` → `editions/desktop/shopno-os-desktop-multimedia`, `cups` → `editions/desktop/shopno-os-desktop-print` |
| `zstdatmel-firmware` | `zstd` + `atmel-firmware` | `zstd` → `base/shopno-os-utils`, `atmel-firmware` → `base/shopno-os-hardware` |
| `shim-unsignedfonts-beng` | `shim-unsigned` + `fonts-beng` | `shim-unsigned` → `base/shopno-os-base`, `fonts-beng` → `editions/desktop/shopno-os-fonts` |
| `calamares-settings-debianarduino` | `calamares-settings-debian` + `arduino` (verify) | `calamares-settings-debian` → `editions/desktop/shopno-os-calamares`, `arduino` → `editions/pro/` if confirmed |

### Custom / Internal Packages

These follow a `shopno-os-*` naming scheme inconsistent with the `shopno-os-*` project namespace. Before placing them in any layer, confirm:

1. Are these packages from an external third-party, or internal packages built from this repo?
2. If internal, they should be renamed to `shopno-os-*` for consistency.
3. What APT repository hosts them? Add it to `base/config/archives/`.

| Package | Suggested Layer (once verified) |
|---------|-------------------------------|
| `shopno-os-debug` | `editions/desktop/` or `editions/pro/` |
| `shopno-os-games` | `editions/desktop/shopno-os-desktop-apps` |
| `shopno-os-log-sync` | `base/` or `editions/desktop/` |
| `shopno-os-looks` | `flavors/<de>/` (theming — DE-specific) |
| `shopno-os-refresh-menu` | `editions/desktop/` |
| `shopno-os-stats-sync` | `base/` or `editions/desktop/` |
| `jadupc-remote-support-console` | `editions/desktop/` once origin is confirmed |

---

## The Bluetooth Split

Bluetooth is split across three layers by function, not by convention:

| Package | Layer | Reason |
|---------|-------|--------|
| `bluetooth` | `base/shopno-os-hardware.list.chroot` | Kernel-level daemon — needed even on headless systems |
| `bluez` | `base/shopno-os-hardware.list.chroot` | Core bluetooth protocol stack |
| `bluez-firmware` | `base/shopno-os-hardware.list.chroot` | Firmware blobs — belongs with other firmware |
| `bluez-tools` | `editions/desktop/shopno-os-desktop.list.chroot` | CLI tools — only useful with a desktop session |
| `blueman` | `flavors/xfce/shopno-os-xfce.list.chroot` | GTK GUI frontend — DE-specific, not all flavors use it |

This pattern — core stack in base, CLI tools in edition, GUI frontend in flavor — is the correct model for any hardware subsystem that has both headless and GUI components.

---

## Enforcement

Run this before every commit:

```bash
./scripts/dev/lint-packages.sh
```

It scans every `.list.chroot` file across `base/`, `editions/`, `flavors/`, and `hardware/` and fails immediately if any package name appears in more than one layer. The error output names the package and every file it appears in.

It also runs automatically in CI on every push via `.github/workflows/lint-packages.yml`. A push with duplicate packages will not pass CI.

If you are adding a new package and lint fails because it already exists somewhere, do not add a second entry — find the existing entry and confirm whether it is in the right place. If it is, you do not need to add the package at all.
