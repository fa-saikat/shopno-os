# Edition: `gaming`

## What This Edition Is

> TODO: Describe what this edition is, who it's for, and what capability it adds.

## What It Includes

> TODO: List the key packages and capabilities this edition provides.

## What It Deliberately Excludes

| Excluded | Reason |
|---|---|
| Desktop environment / WM | Flavor layer responsibility |
| Hardware drivers | Hardware layer responsibility |
| *Add rows as appropriate* | |

## Target Use Cases

> TODO: Who is this edition for?

## Build Command

```bash
# First create a profile, then:
./scripts/build/build.sh shopno-os-gaming-<flavor>
```

## Package Lists

| File | Contents |
|---|---|
| `shopno-os-gaming.list.chroot` | Core edition packages |

## Hooks

| Hook | Stage | Purpose |
|---|---|---|
| `0010-gaming-setup.hook.chroot` | chroot | Initial edition setup |
| `9065-install-shopno-shell.hook.chroot` | chroot | Installs the `shopno-shell` .deb, pinned by SHA-256 |

## Session

The live ISO logs in to Xfce, as before, so Calamares can be run from it. Installed systems log in to [shopno-shell](https://github.com/fa-saikat/shopno-shell) (#112), which is the home screen for the Desktop, Retro Gaming and Smart TV modes.

- **What installs it:** `9065-install-shopno-shell` installs the package. Until it has a release URL, a local build takes the `.deb` from `config/includes.chroot/usr/local/src/shopno-shell/`. `*.deb` is gitignored, and the hook deletes that folder so it doesn't ship.
- **What the package owns:** the session (`shopno.desktop`), its systemd user units, the home screen and the gamepad profiles. The package doesn't touch `/etc`, and it doesn't register as `x-session-manager`. So the live session keeps LightDM's default, `lightdm-xsession`, which starts Xfce.
- **What this edition owns:**
  - Calamares `modules/displaymanager.conf` sets `defaultDesktopEnvironment` to `shopno`. Calamares then writes `user-session=shopno` into the installed system's `lightdm.conf`. Without that setting, it would detect Xfce and write `user-session=xfce`.
  - `shopno-os-firstboot` creates the welcome app's flag file, which the shell reads.
