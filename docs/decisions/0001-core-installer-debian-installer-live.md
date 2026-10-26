# 0001 — Core edition installs via debian-installer in live mode

- **Status:** Accepted
- **Date:** 2026-10-26
- **Issue:** #91

## Context

`shopno-os-core` boots a live session but cannot install to disk. The desktop
and gaming editions install through Calamares; core never got an install path.

Core is TTY-only by definition (`DISTRO_FLAVOR="none"`: no display server, no
DE). Any installer it ships must run on a text console, including a serial
console (`ttyS0`), which is how the boot gate drives QEMU.

Relevant facts about the current build:

- The build runs each profile's own `profiles/<profile>/lb_config.sh`, not
  `profiles/_template/lb_config.sh`. Core's `lb_config.sh` passes no
  `--debian-installer`, so live-build's default (`none`) applies.
- `base/config/bootloaders/grub-pc/` already carries live-build's installer
  menu templates (`install_start_text.cfg`, `@ENABLE_INSTALL_MENU@`,
  `@APPEND_INSTALL@`). They stay inert until an installer is enabled.
- `profiles/shopno-os-core/profile.env` already defines an empty
  `LB_BOOTAPPEND_INSTALL`, which nothing consumes yet.
- The template's comment on `--debian-installer` is wrong: it says `live`
  means "no Debian installer on the ISO". Per `lb_config(1)`, `live` includes
  the `live-installer` udeb, which installs the live system to disk.

## Decision

Core installs with **debian-installer (d-i) in live mode**
(`lb config --debian-installer live`), text frontend only.

1. **Installer type: `live`.** d-i copies the live squashfs to disk instead of
   installing packages from a mirror. The installed rootfs is the same rootfs
   the live boot gate and package gate already test. Installation needs no
   network. live-build writes `live/filesystem.packages-remove`, and d-i
   purges the packages it lists (`live-boot`, `live-config`, …) from the
   target.
2. **Text frontend only.** Set `--debian-installer-gui false`, so the ISO
   carries no graphical d-i, matching the TTY-only edition.
3. **Profile-driven, off by default.** New `profile.env` variables
   (`LB_DEBIAN_INSTALLER`, `LB_DEBIAN_INSTALLER_GUI`) are passed through by
   core's `lb_config.sh`. Desktop and gaming are unchanged and keep Calamares.
4. **Screen first, serial second, on the install entry.** d-i runs on
   `/dev/console`, which is the *last* `console=` argument, so
   `LB_BOOTAPPEND_INSTALL` is `console=ttyS0,115200n8 console=tty0`: the
   installer appears on screen for bare-metal installs, and serial still gets
   kernel output. Headless installs (tests) boot d-i's kernel directly and
   pass their own `console=ttyS0`.
5. **Interactive install is the user-facing path.** The ISO's GRUB menu
   offers the normal text "Install" entry. d-i asks for disk, user and
   hostname as usual. No root password is set by default, so the first user
   gets `sudo` (already in `base`).
6. **The automated install exists for testing and is not on the menu.** The
   initrd carries defaults only (written by the branding hook, e.g. the
   hostname with `seen false`, so the question is still asked), loaded by its
   own startup script. They must *not* go in the initrd's `/preseed.cfg`:
   d-i's `reopen-console` treats that file as preseeding and then runs the
   installer on a single console, which put it on serial instead of the
   screen in the first local test. The unattended preseed
   ships on the ISO under `includes.binary` and is used only when a test
   boots d-i's kernel directly with
   `auto=true priority=critical preseed/file=…`. The stock "Automated install"
   entry under *Advanced install options* stays: without a preseed it still
   asks before partitioning. The ISO has no menu entry that wipes a disk
   without asking.
7. **Prove it locally first, then in CI.** The install test (install to a
   virtual `qcow2` disk, boot that disk, require the boot marker) must pass on
   a local KVM host before any CI job runs it. In CI it starts as a
   non-blocking metric and graduates to a gate on measured evidence, like the
   boot gate did (#87).

## Alternatives considered

- **Calamares for core.** Rejected: Calamares has no text frontend. Running it
  needs a display server, Qt and a kiosk compositor, which ends TTY-only.
- **Custom `shopno-install` script** (partition, rsync the squashfs, install
  GRUB). Rejected for now: we would own partitioning, BIOS and UEFI
  bootloader install, LUKS and fstab, all of which d-i already handles. Revisit
  only if d-i live mode proves unworkable.
- **Prebuilt disk images** (mmdebstrap → qcow2/raw). Not rejected, deferred:
  a good complement for VM and cloud users, but it does not make the ISO
  installable on bare metal.
- **Keep core live-only (wontfix #91).** Rejected: an ISO edition presented as
  a "server base" should install.

## Consequences

- The core ISO grows by the size of the d-i kernel and initrd plus udebs
  (expected tens of MB). Measure it, and update size or count floors if any
  gate trips.
- The installed system's boot path (fstab, initramfs without `live-boot`,
  `grub-install` to the disk's ESP, NVRAM entry) becomes something we must
  test. The live boot gate does not cover any of it.
- The boot marker must show that a boot came from the installed disk and not
  the live medium. Otherwise a disk-boot test could pass by booting the ISO.
- Only the UEFI path is tested, like the existing boot gate. The legacy BIOS
  path remains untested (#30).
- Desktop and gaming still have no install test. This ADR does not change
  that, though the harness built here could later cover Calamares too.
- The installer must not present itself as Debian. Chroot hooks cannot reach
  d-i (`lb installer` runs before `lb binary`), so branding is one
  `*.hook.binary` that repacks the d-i initrd: it patches an allowlist of
  English template strings (failing the build when one disappears upstream),
  rewrites the identity keys of `/etc/lsb-release` in place (other keys are
  read by d-i, so a whole-file `config/includes.installer/` override would
  break it), and appends preseed defaults. A second binary hook rewrites the
  medium label in `.disk/info`, which live-build hard-codes as "Debian
  GNU/Linux" and d-i uses as the CD's name. Strings
  in udebs loaded from the ISO pool at install time are audited separately;
  patching them means repacking udebs and regenerating the pool index (#102).
