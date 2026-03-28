# Git Usage Guide: ShopnoOS
> How we use Git and GitHub in this project. Read before your first commit.

---

## Branches

| Branch | Purpose | Rule |
|---|---|---|
| `main` | Stable, buildable, released | Never commit directly - merge from `dev` only |
| `dev` | Active development | Default working branch |
| `feature/<name>` | Isolated feature work | Branch from `dev`, merge back to `dev` |
| `hotfix/<name>` | Urgent fix to a release | Branch from `main`, merge to both `main` and `dev` |

**Day-to-day:** you are on `dev`. Always.

```bash
# Start a new feature
git checkout dev
git checkout -b feature/add-hyprland-flavor

# Done - merge back
git checkout dev
git merge feature/add-hyprland-flavor
git branch -d feature/add-hyprland-flavor
```

---

## Commit Message Format

```
<prefix>: <short description in lowercase>
```

One line. No period at the end. Under 72 characters.

### Layer Prefixes

Use the layer prefix that matches where the change lives.

| Prefix | When to use |
|---|---|
| `base:` | Changes inside `base/` |
| `edition(<name>):` | Changes inside `editions/<name>/` |
| `flavor(<name>):` | Changes inside `flavors/<name>/` |
| `hardware(<name>):` | Changes inside `hardware/<name>/` |
| `brand:` | Changes inside `brand/` |
| `profiles:` | Changes inside `profiles/` |
| `build:` | Build scripts and pipeline (`scripts/build/`) |
| `scripts:` | Shared script library (`scripts/lib/`, `scripts/dev/`) |
| `tools:` | In-ISO tools (`tools/`) |
| `docs:` | Documentation only - no functional change |
| `tests:` | Test and lint scripts |
| `fix:` | Something broken that caused or would cause a build/runtime failure |
| `chore:` | Housekeeping with no behavior change (cleanup, deduplication, renaming) |
| `release:` | Version bump, tag, changelog update |

### Examples

```
base: add auditd to abrar-security.list.chroot
edition(desktop): split multimedia packages into separate list
edition(pro): add virt-manager to abrar-pro-virt.list.chroot
flavor(xfce): add xcape and xclip to abrar-input.list.chroot
flavor(xfce): add wget hook for neohtop until packaged in apt repo
hardware(nvidia): initial nvidia layer scaffold
brand: update DISTRO_CODENAME to Noor
profiles: add abrar-desktop-xfce profile
build: fix symlink logic in inject-packages.sh
scripts: add lint-packages.sh duplicate detection
tools: add calamares bootloader.conf for efi targets
docs: add package-ownership runbook
fix: correct malformed ibus-avro entry in abrar-input.list.chroot
chore: remove duplicate package entries from package lists
release: bump version to 1.1 in brand/identity/name.env
```

### When to add a body

Most commits don't need one. Add a body when:
- The *why* is not obvious from the diff
- You're working around a bug in an upstream package
- A decision was made that future you will question

```
flavor(xfce): install ttf-bijoy via wget hook

Upstream does not publish to any Debian repo. Installing via dpkg -i
from a direct download until we package and host it ourselves.
Tracked in: https://github.com/JaduPC/shopno-os/issues/2
```

---

## Tagging and Releases

Tags live on `main`. Always.

```bash
# Make sure main is up to date with tested dev work
git checkout main
git merge dev

# Create annotated tag - always annotated, never lightweight
git tag -a v1.0 -m "ShopnoOS 2.0 (Trixie) - stable release"
git push origin main
git push origin v1.0
```

### Tag naming

Tags mirror `DISTRO_VERSION` in `brand/identity/name.env`, prefixed with `v`.

```
v1.0      ← stable release
v1.1      ← minor release (new packages, flavor updates)
v2.0      ← major release (new edition, breaking build changes)
```

When you bump `DISTRO_VERSION` in `name.env` - that's your signal to tag after merging to `main`.

---

## What Never Goes in Git

The `.gitignore` handles most of this automatically, but know the rules:

| What | Why |
|---|---|
| `build/` directory | Live-build artifacts - gigabytes of generated files |
| `*.iso` files | Binary artifacts - use GitHub Releases for these |
| `*.deb` files | Binaries - use wget hooks or APT repo instead |
| `*.key`, `*.pem`, `*.asc` | Signing keys - never, under any circumstances |
| `build.log` | Generated at build time |

If you accidentally commit any of the above:

```bash
# Remove from tracking without deleting the file
git rm --cached path/to/file
git commit -m "chore: remove accidentally tracked file"
```

---

## GitHub Issues

Issues are repo-level, not branch-level. Open them from anywhere.

### Issue title format

```
[<area>] Short description of the problem or task
```

Areas: `packaging`, `build`, `flavor`, `edition`, `hardware`, `brand`, `docs`

```
[packaging] Package neohtop into Abrar APT repo (remove wget hook)
[build] lint-packages.sh does not catch cross-list duplicates
[flavor] Add hyprland flavor scaffold
```

### Referencing issues in commits

When a commit directly addresses an issue, reference it in the body:

```
fix: correct download URL for printer-driver-xprinter hook

Upstream moved the release asset to a new path.
Fixes: #3
```

GitHub will auto-close issue #3 when this commit lands on `main`.

---

## Quick Reference

```bash
# Start work
git checkout dev
git pull origin dev

# Check what you've changed
git status
git diff

# Stage and commit
git add base/package-lists/abrar-security.list.chroot
git commit -m "base: add apparmor and ufw to security list"

# Push dev
git push origin dev

# Merge to main for a release
git checkout main
git merge dev
git tag -a v1.1 -m "ShopnoOS 2.1 (Trixie) - desktop edition update"
git push origin main
git push origin v1.1

# Check history for a specific layer
git log --oneline -- flavors/xfce/
git log --oneline -- base/package-lists/
```

---

*When in doubt: commit small, commit often, use the right prefix. The log is your future self's documentation.*
