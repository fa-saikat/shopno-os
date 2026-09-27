# CI/CD

> How ShopnoOS's GitHub Actions workflows work: what runs on what trigger, why `main` never rebuilds, what broke getting here, and what's still open.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Workflows](#2-workflows)
   - [`lint-packages.yml`](#21-lint-packagesyml)
   - [`build-iso.yml`](#22-build-isoyml)
3. [Trigger Reference](#3-trigger-reference)
4. [Branch Model — Why `main` Never Rebuilds](#4-branch-model--why-main-never-rebuilds)
5. [Toolchain Workarounds](#5-toolchain-workarounds)
6. [Package-Presence Gate](#6-package-presence-gate)
7. [Boot Gate](#7-boot-gate)
8. [Known Limits (Measured, Not Feared)](#8-known-limits-measured-not-feared)
9. [Tracked Follow-ups](#9-tracked-follow-ups)
10. [Related Docs](#10-related-docs)

---

## 1. Overview

Two workflows exist today, both under `.github/workflows/`:

| Workflow | File | Status |
|---|---|---|
| Lint | `lint-packages.yml` | Live, green, every push + PR |
| Build ISO | `build-iso.yml` | Live, matrix `core` + `desktop-xfce` on PRs, green; gaming dispatch-only |

Neither workflow rebuilds on `main`. A tag-triggered `release.yml` (build, sign, publish) is deliberately declined, not pending — see ADR-006; releases run locally per `docs/release-process.md`.

---

## 2. Workflows

### 2.1 `lint-packages.yml`

Runs the four fast, no-build-required checks documented in `docs/package-ownership.md` and `docs/branding-guide.md`:

1. `tests/lint/check-duplicate-packages.sh` — Golden Rule, per layer instance
2. `tests/lint/check-no-hardcoded-names.sh` — branding isolation
3. `tests/lint/check-brand-vars-used.sh` — declared-vs-used brand variables
4. `scripts/dev/lint-packages.sh` — the same script `build.sh` runs before every build (naming convention, empty lists, package-name format, intra-list duplicates, edition/flavor duplicates, layer-policy violations)

No build, no root, no live-build toolchain — finishes in roughly 35 seconds. `paths-ignore` skips runs that can't trip a lint check at all (`docs/**`, `**/*.md`, `CHANGELOG.md`). No `workflow_dispatch` — this is a known asymmetry (see [§3](#3-trigger-reference)): there is currently no button to force a standalone lint run outside a push or PR.

### 2.2 `build-iso.yml`

Builds one ISO on a GitHub-hosted `ubuntu-24.04` runner and runs both smoke tests against it:

```
Checkout
  → Free disk space (reclaim ~gigabytes of preinstalled toolchains never used)
  → Install build dependencies (+ pinned Debian trixie live-build/keyring — see §5)
  → build.sh <profile> --skip-sign --jobs $(nproc)
  → Locate built ISO
  → Package-presence smoke test        (blocking)
  → Boot gate smoke test               (continue-on-error — metric-first)
  → Upload artifacts (if: always())
```

`--skip-sign`: no GPG key lives on a hosted runner. Signing stays a release-machine step via `scripts/release/sign-iso.sh`; CI proves the bits, a release blesses them. Lint is **not** skipped — `build.sh`'s own lint stage runs as defense in depth even though `lint-packages.yml` already gates the same PR.

`if: always()` on the artifact upload exists specifically so a **failed** `lb build` still uploads `build.log` — the step log alone is rarely enough to diagnose a chroot or `lb config` failure, and that's exactly the run where you want the full log.

`workflow_dispatch` takes an optional `profile` input (default `shopno-os-core`) for exercising one profile outside the PR path — this is how `desktop-xfce` was first proven and how `gaming-xfce` stays available without ever running unasked.

---

## 3. Trigger Reference

```
Push to any branch (incl. dev) — triggers lint, does NOT trigger build-iso
A PR to dev                    — triggers both lint and build-iso (core edition)
Merge dev to main               — triggers lint, does NOT trigger build-iso
Manual dispatch                 — does NOT trigger lint, triggers build-iso
```

This is enforced by the trigger blocks themselves, not just intended:

- `build-iso.yml` listens **only** to `pull_request: branches: [dev]` and `workflow_dispatch`. It has no `push` trigger at all — pushing directly to `dev` never fires it.
- `lint-packages.yml` listens to `push` and `pull_request`, neither scoped to a branch — it fires on any push (including the fast-forward merge push that lands on `main`) and any PR. It has no `workflow_dispatch`, so manual dispatch never runs lint.

Reading the row for "a PR to `dev`" carefully: the matrix resolves from event inputs — `pull_request` events carry none, so the run builds the full `["shopno-os-core", "shopno-os-desktop-xfce"]` set; `workflow_dispatch` builds exactly the chosen profile. Gaming never runs unasked (see [§8](#8-known-limits-measured-not-feared)).

---

## 4. Branch Model — Why `main` Never Rebuilds

Per `docs/release-process.md` §1.5 and `docs/git-guide.md`: `dev` is the authoritative branch; `main` is the stable release target and is **never committed to directly** — it only ever receives fast-forward merges of already-proven `dev` state, plus tags.

Rebuilding on `main` would mean re-proving bits that were already proven on `dev` thirty-plus minutes earlier, for a different channel — exactly the "promotion, not rebuild" principle the project already applies elsewhere (aptly's pointer-swap publish model in `shopnos-devops-integration-plan.md` §3, Phase 3). Release verification on `main` is deferred to the tag-triggered `release.yml`, which does not exist yet (see [§9](#9-tracked-follow-ups)).

---

## 5. Toolchain Workarounds

Every item below was a real green-to-red-to-green cycle on an actual CI run, not anticipated in advance:

| Problem | Root cause | Fix |
|---|---|---|
| `lb config` died immediately | Ubuntu Noble ships no `live-build` package at all, and its own resolvable `lb` (if any) rejects flags this project requires (`--uefi-secure-boot`, `--image-name`, `--debootstrap-options`) | Pinned, checksummed Debian trixie `live-build_20250505+deb13u1_all.deb` (arch:all, needs only `cpio` + `debootstrap`), installed via `dpkg -i` before the build step |
| `debootstrap` aborted immediately | Noble's `debian-archive-keyring` (2023.4) predates the trixie archive signing keys | Same pinned-`.deb` treatment: `debian-archive-keyring_2025.1_all.deb`, checksum-verified |
| Desktop build died in `binary_syslinux` | A vendored `isolinux.bin` blob in the repo fought live-build's own symlink mechanism — on a host with `syslinux` installed it silently overwrote a dpkg-owned file (proven byte-identical after the fact); on a host without it (every hosted runner) `cp` refused the dangling symlink outright | Vendored blob removed (issue #40); live-build supplies its own `isolinux.bin` via the `syslinux` package |
| `xorriso` failed to extract gaming/desktop images in the package-presence gate | `xorriso` 1.5.x cannot parse ISO trees containing files over 4GB (multi-extent SUSP `CE` entries) — hit on real gaming and desktop squashfs images | `7z` fallback extraction path added to `tests/smoke/test-packages-present.sh` |
| The 7z fallback then failed on retry | `xorriso`'s partial death on the size limit leaves a **read-only** partial extraction tree behind; `7z` cannot overwrite into it | Wipe the partial tree before invoking the `7z` fallback |

Both pinned `.deb`s are installed with an explicit `sha256sum -c` check — a version bump upstream fails the workflow loudly (wrong checksum) rather than silently installing something un-pinned. Re-pin deliberately when trixie's `live-build` or `debian-archive-keyring` package next moves.

---

## 6. Package-Presence Gate

`tests/smoke/test-packages-present.sh` — **blocking**. Fast, deterministic, no virtualization involved: extracts the squashfs rootlessly (`xorriso`, with the `7z` fallback from [§5](#5-toolchain-workarounds)), single-file-extracts `var/lib/dpkg/status`, and checks the installed package set against `tests/fixtures/expected-package-counts.json`.

Design is deliberately **floor + critical-list, not exact count**: exact counts rot on every upstream Debian change and train people to bump numbers blindly without checking why. A floor catches catastrophic drops; the critical-package list catches layer-merge regressions deterministically, independent of total count drift.

All three fixture profiles (`shopno-os-core`, `shopno-os-desktop-xfce`, `shopno-os-gaming-xfce`) are now validated against real built ISOs (`validated_against_real_iso: true`, with a `validated_detail` block recording the source ISO, observed count, critical-package hit rate, and validation date) — floors sit roughly 17-19% below the observed real count, a consistent cushion across all three:

| Profile | Floor (`total_min`) | Observed | Cushion |
|---|---|---|---|
| `shopno-os-core` | 650 | 784 | ~17% |
| `shopno-os-desktop-xfce` | 1500 | 1812 | ~17% |
| `shopno-os-gaming-xfce` | 1500 | 1852 | ~19% |

`gaming-xfce`'s floor is validated from a real **local** build, not a CI one — see [§8](#8-known-limits-measured-not-feared) for why gaming doesn't run on hosted CI at all.

---

## 7. Boot Gate

`tests/smoke/test-iso-boots.sh` — **`continue-on-error: true`, metric-first, not yet a hard gate**. Boots the ISO headlessly under QEMU/OVMF (UEFI path only — see the BIOS gap in [§9](#9-tracked-follow-ups)) and checks the serial log for the boot-marker service's verdict, gated on `multi-user.target` specifically rather than the edition's default target (full detail on why in `docs/decisions/002-boot-gate-target-scope.md`).

This follows the project's own non-blocking-first pattern already established for `grype` scanning in the broader DevOps plan (`distro-devops-architecture.md` §3.7): prove the check locally, run it in CI as a metric, promote to blocking once it's shown to be reliable in the actual CI environment — not the moment it merges.

It's `continue-on-error` specifically because the **hosted runner has no `/dev/kvm`** — QEMU falls back to TCG software emulation, which is measurably slower than the KVM-accelerated boot every local test has run under. `core` (headless) currently boots within the 600-second CI budget under TCG; `desktop-xfce` does not — it exceeds the timeout under TCG despite booting fine locally under KVM. That gap is real, measured, and is the standing justification for eventually moving to a self-hosted KVM-capable runner rather than a reason to distrust the check itself.

---

## 8. Known Limits (Measured, Not Feared)

- **No `/dev/kvm` on hosted runners.** TCG-only. `core` headless is plausible in-budget; `desktop-xfce` is not (see [§7](#7-boot-gate)). This is the measured trigger for a self-hosted runner, not a theoretical concern.
- **`gaming-xfce` does not run on hosted CI at all.** The gaming ISO is 10GB+ once RetroPie ROM and emulator artifacts are included, and those artifacts cannot be pushed to GitHub — only the RetroPie/emulator *configuration* is tracked in git. Its fixture floor is validated from a real local build instead.
- **`vm`-hardware target work is deliberately out of scope for now**, not an oversight. CI is scoped to `core` and `desktop` — the most feasible profiles to test on a GitHub-hosted runner — until hardware-specific build work is actually underway.
- **The legacy-BIOS boot path has no serial configuration.** `test-iso-boots.sh` exercises the UEFI (`grub-efi`) path only; a `SERIAL` directive is still needed in `base/config/bootloaders/isolinux/` and `syslinux/` before a `--bios legacy` boot would produce anything but a silent hang waiting on a console nothing is feeding (tracked as issue #30).

---

## 9. Tracked Follow-ups

- **`SOURCE_DATE_EPOCH`** wiring into `lb_config.sh`, per `shopnos-devops-integration-plan.md` Phase 1 — not started.
- **Boot-gate promotion** from metric to blocking gate — gated on either a self-hosted KVM runner landing, or N consecutive green `core` boots under TCG establishing the check is reliable in this environment specifically.
- **Matrix build**: `core` + `desktop` on PRs, `gaming` on dispatch-only (never PR-triggered, given its size — see [§8](#8-known-limits-measured-not-feared)).
- **Self-hosted runner.** Per `shopnos-devops-integration-plan.md` §3, this is a one-line change (`runs-on: ubuntu-24.04` → `runs-on: [self-hosted, linux, iso-builder]`) once hosted-runner disk, time, or KVM limits are actually hit and measured — not before.
- **No `release.yml`, by decision** (ADR-006): tag-triggered build-sign-publish declined — releases stay local/manual.
- **BIOS serial console gap** (issue #30) — see [§8](#8-known-limits-measured-not-feared).
- **`lint-packages.yml` has no `workflow_dispatch`** — no way to force a standalone lint run today outside a push or PR.

---

## 10. Related Docs

- `docs/architecture.md` §13 — original CI/CD design intent (some entries here supersede it; where they conflict, this document reflects what's actually deployed)
- `docs/release-process.md` — the manual release checklist this workflow does not yet automate
- `docs/package-ownership.md`, `docs/branding-guide.md` — what `lint-packages.yml` actually enforces
- `docs/decisions/001-profile-composition-model.md`, `docs/decisions/002-boot-gate-target-scope.md` — ADRs referenced above
- `shopnos-devops-integration-plan.md`, `distro-devops-architecture.md` — the broader roadmap these workflows are the first phase of

---

*This document reflects what the workflows actually do, verified line-by-line against the committed YAML — not what earlier planning docs proposed. Where the two disagree, this one wins.*
