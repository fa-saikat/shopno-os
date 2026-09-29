# Release Process

> Step-by-step checklist for producing a signed, published ShopnoOS release.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 - Preparation](#3-phase-1--preparation)
4. [Phase 2 - Version Bump](#4-phase-2--version-bump)
5. [Phase 3 - Build All Release ISOs](#5-phase-3--build-all-release-isos)
6. [Phase 4 - Verification](#6-phase-4--verification)
7. [Phase 5 - Sign and Finalise](#7-phase-5--sign-and-finalise)
8. [Phase 6 - Tag and Publish](#8-phase-6--tag-and-publish)
9. [Phase 7 - Post-Release](#9-phase-7--post-release)
10. [Rollback Procedure](#10-rollback-procedure)
11. [Release Checklist (printable)](#11-release-checklist-printable)

---

## 1. Overview

A release is a tagged, signed, published set of ISOs covering all supported profiles. The process has seven phases:

```
Preparation → Version Bump → Build → Verify → Sign → Publish → Post-Release
```

Phases 3–6 run locally, by hand, on a machine holding the GPG key and mirror access — no tag-triggered CI rebuild exists, deliberately: a rebuild would produce different bits than the ones Phase 4 verified, violating the promotion-not-rebuild rule (§1.5). CI's role ends at proof (`build-iso.yml` gates every PR on `dev`); the tag, created in §8.1 *after* building and verifying, marks the proven state and triggers nothing. A `release.yml` automating phases 3–6 is explicitly declined not deferred — the GitHub Release itself is one local command (`gh release create`, §8.4). This document is the authoritative checklist, not a fallback for missing automation.

**Release scripts involved:**

| Script | Purpose |
|--------|---------|
| `scripts/release/sign-iso.sh` | GPG-signs an ISO and produces `.sha256`, `.sha512`, `.gpg` |
| `scripts/release/publish.sh` | Uploads ISO and artifacts to the mirror / release server |
| `scripts/release/changelog-gen.sh` | Auto-generates a `CHANGELOG.md` entry from git log |

### 1.5 Branch Flow

Everything through signing happens **on `dev`** -  lint, changelog, the version-bump commit, all builds, all Phase 4 verification, and signing. `dev` is the authoritative branch; a release is proven there before it touches `main` at all.

```
dev ---> lint ---> changelog ---> version bump ---> build ---> verify ---> sign ---.
                                                                             	   |
main <-------------------------- merge dev into main <-----------------------------`
 |
 `---> tag v<VERSION> on main ---> push ---> publish.sh (same bits, no rebuild) ---.
																			 	   |
GitHub Release <-------------------------------------------------------------------`
```

Only **after** `dev` has passed every Phase 4 check do you flip `main`:

```bash
git checkout main
git merge dev
```

This must be a clean fast-forward — nothing else ever commits to `main` directly (see `docs/git-guide.md`), so if the merge isn't a fast-forward, stop and investigate before tagging anything.

The tag is then created **on `main`**, never on `dev` - see §8.1. Tagging comes after building and verifying, not before: a tag means "this exact commit is released," so building first means a tag is only ever created for a commit that has already proven itself. This is the same reasoning behind `aptly`'s promotion-by-pointer-swap in the DevOps integration plan - you never rebuild for a different channel, you promote bits that already passed.

Phase 7's post-release version bump happens back **on `dev`** - it marks the start of the next development cycle, which by definition isn't a released state and doesn't belong on `main`.

## 2. Prerequisites

### GPG Signing Key

The release signing key must be available to the user running the build. Verify it is present:

```bash
gpg --list-secret-keys
```

The key used for signing must match the fingerprint published in the project's trust document and on the website's download page. If the key has expired or needs rotating, do that before starting the release - do not release with an expired key.

Import the key on a fresh machine:

```bash
gpg --import /path/to/release-key.asc
gpg --edit-key <KEY_ID>
# trust → 5 (ultimate) → quit
```

### Build Environment

The release build host must meet the same requirements as a regular build (see `docs/build-guide.md` §1), plus:

- GPG key configured and trusted (above)
- SSH access to the mirror/release server configured in `scripts/release/publish.sh`
- Sufficient disk space for all profiles simultaneously: plan for ~15 GB per ISO × number of profiles

### Clean Working Tree

The release must be built from a clean, committed state. Verify before starting:

```bash
git status
# Expected: nothing to commit, working tree clean

git log --oneline -5
# Confirm you are on the correct branch and commit
```

Do not release from a dirty working tree. Uncommitted changes will not be reproducible and will not match what is tagged.

---

## 3. Phase 1 - Preparation

### 3.1 Confirm the release scope

Decide which profiles are included in this release. The standard set is all non-`_template` profiles:

```bash
ls profiles/ | grep -v _template
```

For a point release fixing a single issue, you may rebuild only the affected profiles. Document the scope in the release notes.

### 3.2 Run all lint checks

```bash
./scripts/dev/lint-packages.sh
./tests/lint/check-duplicate-packages.sh
./tests/lint/check-no-hardcoded-names.sh
./tests/lint/check-brand-vars-used.sh
```

All four must pass cleanly. Fix any failures before proceeding. A lint failure means the build will either fail outright or produce a broken ISO - there are no exceptions.

### 3.3 Verify brand identity is correct

```bash
cat brand/identity/name.env
```

Confirm `DISTRO_NAME`, `DISTRO_VERSION`, `DISTRO_CODENAME`, and all URLs are what you intend to ship. The version in `name.env` is what will appear in every ISO filename, in `/etc/os-release` on every installed system, and in the git tag. Get it right before building.

### 3.4 Review `CHANGELOG.md`

Generate a draft changelog entry for the release:

```bash
./scripts/release/changelog-gen.sh
```

Review the output, edit as needed, and commit the updated `CHANGELOG.md` before building. The changelog must be committed before tagging so it is included in the tagged state.

### 3.5 Confirm all profiles build cleanly in dry-run

```bash
for profile in $(ls profiles/ | grep -v _template); do
    echo "--- Dry run: ${profile} ---"
    sudo ./scripts/build/build.sh "${profile}" --dry-run
done
```

Dry run does not require a full build but catches profile validation errors, missing brand variables, and malformed `profile.env` files before you invest build time.

---

## 4. Phase 2 - Version Bump

### 4.1 Update `brand/identity/name.env`

```bash
# Edit the version and codename as appropriate
nano brand/identity/name.env
```

```bash
DISTRO_NAME="ShopnoOS"
DISTRO_CODENAME="Shopno"
DISTRO_VERSION="1.1"          ← bump this
DISTRO_ID="shopno-os"
DISTRO_ID_LIKE="debian"
DISTRO_WEBSITE="https://shopno.jadupc.com"
DISTRO_BUGTRACKER="https://github.com/JaduPC/shopno-os/issues"
```

**Version format rules** (enforced by `brand.sh` at build time):
- Digits and dots only: `1.0`, `1.1`, `1.0.1`, `2024.01`
- No `v` prefix - the git tag will carry that
- Must be strictly greater than the previous release version

### 4.2 Verify the version parses correctly

```bash
# Quick sanity check - brand.sh will validate on build, but catch it early
(
    source scripts/lib/common.sh
    source scripts/lib/brand.sh
    source scripts/lib/profile.sh
    source scripts/lib/iso-name.sh

    echo "Version: ${DISTRO_VERSION}"
    echo ""
    echo "ISO names for all available profiles:"

    for profile in $(list_profiles); do
        if ! iso="$(load_profile "${profile}" >/dev/null 2>&1 && iso_name)"; then
            echo "  ${profile} → ERROR (failed to load profile)"
            continue
        fi
        echo "  ${profile} → ${iso}"
    done
)
```

### 4.3 Confirm ISO names look correct

The ISO name is derived deterministically. Verify what it will produce for each profile before committing:

```bash
# For profile shopno-os-desktop-gnome with DISTRO_VERSION="1.1":
# Expected: shopno-os-1.1-desktop-gnome-amd64-<BUILDDATE>.iso
```

### 4.4 Commit the version bump

```bash
git add brand/identity/name.env CHANGELOG.md
git commit -m "release: bump version to ${DISTRO_VERSION}"
```

Do not include any other changes in this commit. The version bump commit must be clean and easily identifiable in the log.

---

## 5. Phase 3 - Build All Release ISOs

Build each profile in sequence. Parallel builds on the same machine are possible but compete for disk I/O - sequential is safer unless you have separate build volumes.

```bash
for profile in \
    shopno-os-core \
    shopno-os-desktop-gnome \
    shopno-os-desktop-kde \
    shopno-os-desktop-xfce \
    shopno-os-pro-gnome \
    shopno-os-pro-kde
do
    echo "========================================="
    echo "Building: ${profile}"
    echo "========================================="
    sudo ./scripts/build/build.sh "${profile}" --output-dir /srv/release/staging/
done
```

Each build produces its ISO, `.sha256`, `.sha512`, `.gpg`, and `build-manifest.json` in the staging directory.

> **Note:** Do not use `--skip-lint` or `--skip-sign` for release builds. Both are required.

If any build fails, do not continue to the next phase. Fix the failure, clean the failed build directory, and rebuild that profile:

```bash
sudo ./scripts/build/clean.sh <failed-profile>
sudo ./scripts/build/build.sh <failed-profile> --output-dir /srv/release/staging/
```

---

## 6. Phase 4 - Verification

This phase must be completed before signing and publishing. Do not skip it for point releases.

### 6.1 Verify all expected artifacts are present

```bash
ls /srv/release/staging/
```

Expected for each profile:
```
shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.iso
shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.sha256
shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.sha512
shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.iso.gpg
build-manifest.json
```

Naming rule (matches `iso_checksum_filename` / `iso_signature_filename` in `scripts/lib/iso-name.sh`): checksum files follow the *stem* (no `.iso` infix), the signature follows the full ISO name. Never hand-construct these — derive them as the commands below do.

If any artifact is missing, that profile's build did not complete successfully. Do not proceed.

### 6.2 Verify checksums

```bash
cd /srv/release/staging/
for iso in *.iso; do
    echo "Verifying: ${iso}"
    sha256sum -c "${iso%.iso}.sha256" && echo "  SHA256: OK" || echo "  SHA256: FAILED"
    sha512sum -c "${iso%.iso}.sha512" && echo "  SHA512: OK" || echo "  SHA512: FAILED"
done
```

All must pass. A checksum failure means the ISO was corrupted or the signing step wrote the checksum before the ISO was fully written. Rebuild the affected profile.

### 6.3 Verify GPG signatures

```bash
for iso in *.iso; do
    echo "Verifying signature: ${iso}"
    gpg --verify "${iso}.gpg" "${iso}" && echo "  GPG: OK" || echo "  GPG: FAILED"
done
```

### 6.4 Verify `/etc/os-release` in each ISO

Mount the squashfs from each ISO and confirm the version is correct:

```bash
# Mount an ISO and inspect os-release
iso="shopno-os-1.1-desktop-gnome-amd64-20250301.iso"
mkdir -p /mnt/iso /mnt/squash

mount -o loop "${iso}" /mnt/iso
mount -o loop /mnt/iso/live/filesystem.squashfs /mnt/squash

cat /mnt/squash/etc/os-release

umount /mnt/squash
umount /mnt/iso
```

Confirm:
- `NAME` matches `DISTRO_NAME` in `brand/identity/name.env`
- `VERSION_ID` matches `DISTRO_VERSION`
- `VERSION_CODENAME` matches `BASE_DISTRIBUTION` (lowercased) — deliberately the Debian suite (`trixie`), not `DISTRO_CODENAME`: external tools reading os-release expect a real suite name (see `base/hooks/chroot/0090-stamp-build-info.hook.chroot`)
- `HOME_URL` and `BUG_REPORT_URL` are correct
- `BUILD_ID` includes today's date

### 6.5 Smoke test at least one ISO

Boot the ISO in QEMU and verify it reaches the live desktop:

```bash
./tests/smoke/test-iso-boots.sh /srv/release/staging/shopno-os-1.1-desktop-xfce-amd64-20250301.iso
```

The smoke test verifies the ISO boots to a login prompt and that a defined set of packages is present. Run it against at minimum the `desktop-xfce` ISO (smallest desktop ISO, fastest to test) and the `core` ISO.

### 6.6 Verify build manifests

```bash
for manifest in /srv/release/staging/build-manifest.json; do
    echo "=== ${manifest} ==="
    jq '{edition: .build.edition, flavor: .build.flavor, hardware: .build.hardware, version: .distro.version, date: .build.date}' "${manifest}"
done
```

Confirm the version, edition, and flavor in each manifest match the expected values for that ISO.

---

## 7. Phase 5 - Sign and Finalise

If the builds were produced with `--skip-sign` during testing, sign them now. If signing ran during the build (default), verify and skip this phase.

### Sign any unsigned ISOs

```bash
for iso in /srv/release/staging/*.iso; do
    if [[ ! -f "${iso}.gpg" ]]; then
        echo "Signing: ${iso}"
        ./scripts/release/sign-iso.sh "${iso}"
    fi
done
```

### Verify the rolling manifests

`sign-iso.sh` maintains rolling `SHA256SUMS` / `SHA512SUMS` itself
(remove-stale-entry plus append per ISO) — never hand-roll them with
`sha256sum *.iso > SHA256SUMS`, which would silently drop ISOs missing
from the glob. Just confirm they exist and cover every staged ISO:

```bash
cd /srv/release/staging/
for iso in *.iso; do
    grep -q "  ${iso}$" SHA256SUMS && echo "  ${iso}: listed" || echo "  ${iso}: MISSING"
done
```

Do not create a detached-signed `SHA256SUMS.asc`: nothing publishes,
uploads, or verifies it (`publish.sh` transfers the unsigned rolling
files). If signed manifests are ever wanted, that's a design change to
`sign-iso.sh` + `publish.sh` + mirror verification together — not a
manual step.

---

## 8. Phase 6 - Tag and Publish

### 8.1 Create and push the git tag

Flip `main` to the state `dev` just proved through Phase 4 and Phase 5, before tagging (see §1.5):

```bash
git checkout main
git merge dev
```

The tag must be created after the version bump commit and before publishing. Tags trigger nothing in CI by design (ADR-006 declined tag-triggered release automation — releases stay local).

```bash
git tag -a "v${DISTRO_VERSION}" -m "Release ${DISTRO_VERSION} (${DISTRO_CODENAME})"
git push origin "v${DISTRO_VERSION}"
```

Tag naming convention: `v` prefix + version number, e.g. `v1.1`, `v1.0.1`, `v2024.01`. The tag message should include the codename.

### 8.2 Publish ISOs to the mirror

Publishing needs mirror credentials in the environment (see
`docs/secrets-management.md`): `OS_MIRROR_HOST`, `OS_MIRROR_USER`,
`OS_MIRROR_PATH`. The script derives version, edition, arch, and the
remote directory from the profile and brand identity — pass neither
by hand:

```bash
for profile in \
    shopno-os-core \
    shopno-os-desktop-xfce \
    shopno-os-gaming-xfce
do
    echo "========================================="
    echo "Publishing: ${profile}"
    echo "========================================="
    ./scripts/release/publish.sh "${profile}" --output-dir /srv/release/staging/
done
```

`publish.sh` uploads that profile's ISO, checksums, signature, and manifest to the configured mirror. The target path on the mirror is:

```
releases/<DISTRO_VERSION>/<EDITION>/<ARCH>/
├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.iso
├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.sha256
├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.sha512
├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>.iso.gpg
├── build-manifest.json
├── SHA256SUMS
├── SHA512SUMS
└── <id>-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-latest.{iso,sha256,sha512,iso.gpg} (symlinks)
```

Verify the upload completed and the files are accessible:

```bash
curl -I "https://mirror.shopno-oslinux.org/releases/${DISTRO_VERSION}/"
```

### 8.3 Promote the container image (`:DISTRO_VERSION`, `:stable`)

The pipeline publishes every `dev` push as `:edge` + short-SHA only. Release tags are promotion, never rebuild: verify the exact digest from the proven `dev` run, then retag that digest. Signatures bind to digests, so both retags stay valid with nothing re-signed.

Take `DIGEST` from the merge-to-`dev` run's step summary ("Image digest: ...") — the run that built the release commit, not whatever `:edge` points at now:

```bash
IMAGE="ghcr.io/fa-saikat/shopno-os"
DIGEST="<digest from the proven dev-push run summary>"
DISTRO_VERSION="$(grep '^DISTRO_VERSION=' brand/identity/name.env | cut -d'"' -f2)"

# Authenticate the exact bits first (public Rekor/Fulcio — no credentials needed):
cosign verify "${IMAGE}@${DIGEST}" \
  --certificate-identity-regexp "^https://github.com/fa-saikat/shopno-os/\.github/workflows/container-build\.yml@refs/heads/dev$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Short-lived push auth only (ephemeral `gh` token — nothing long-lived,
# per ADR-006 as narrowed; cosign never signs here, it only verifies):
echo "$(gh auth token)" | skopeo login ghcr.io -u "$(gh api user --jq .login)" --password-stdin

# Retag the verified digest — no build, no new bits, ever:
skopeo copy "docker://${IMAGE}@${DIGEST}" "docker://${IMAGE}:${DISTRO_VERSION}"
skopeo copy "docker://${IMAGE}@${DIGEST}" "docker://${IMAGE}:stable"
```

One-time setup (first release only): GHCR packages default to private — flip the `shopno-os` package to public under Package settings so third parties can pull and verify. Every later release inherits visibility.

Rules that make this safe: promote only digests whose push run was fully green (push → sign → attest → verify); `:stable` moving under consumers is expected behavior, mirroring the mirror's `latest` symlinks; if verification fails, stop — do not retag around it.

### 8.4 Create a GitHub / Forgejo release

Create the release on the repository host (one local command — no CI involved):

```bash
gh release create "v${DISTRO_VERSION}" \
    --title "ShopnoOS ${DISTRO_VERSION} (${DISTRO_CODENAME})" \
    --notes-file CHANGELOG.md \
    /srv/release/staging/*.iso \
    /srv/release/staging/*.sha256 \
    /srv/release/staging/*.sha512 \
    /srv/release/staging/*.gpg \
    /srv/release/staging/SHA256SUMS \
    /srv/release/staging/SHA512SUMS
```

- Tag: `v${DISTRO_VERSION}`
- Title: `ShopnoOS ${DISTRO_VERSION} (${DISTRO_CODENAME})`
- Body: paste the relevant section from `CHANGELOG.md`
- Attach: all `.iso`, `.sha256`, `.sha512`, `.gpg`, and `SHA256SUMS` files

### 8.5 Update the website download page

Update `DISTRO_RELEASE_URL` references on the website to point to the new release. Confirm direct download links resolve correctly for each ISO before announcing.

---

## 9. Phase 7 - Post-Release

### 9.1 Announce the release

Post the release announcement with:
- Version number and codename
- Summary of what changed (from `CHANGELOG.md`)
- Download links for each ISO
- SHA256SUMS and GPG key fingerprint for verification
- Link to the full release notes

### 9.2 Update the `stable` pointer on the mirror

If your mirror uses a `stable` symlink or redirect:

```bash
# On the mirror server:
ln -sfn releases/${DISTRO_VERSION} releases/stable
```

### 9.3 Bump to the next development version

Immediately after release, bump `brand/identity/name.env` to the next development version to avoid any accidental rebuilds carrying the released version number:

```bash
# e.g. after releasing 1.1, bump to 1.2-dev or simply 1.2
nano brand/identity/name.env
# DISTRO_VERSION="1.2"

git add brand/identity/name.env
git commit -m "dev: bump version to 1.2 post-release"
```

### 9.4 Archive the staging directory

Move the staging build artifacts to long-term storage or delete them. The ISOs are now on the mirror and git preserves the tagged state - the local build artifacts are not needed.

```bash
# Archive:
mv /srv/release/staging/ /srv/release/archive/${DISTRO_VERSION}/

# Or delete if you have disk pressure:
rm -rf /srv/release/staging/
```

### 9.5 Clean build directories

```bash
for profile in $(ls profiles/ | grep -v _template); do
    sudo ./scripts/build/clean.sh "${profile}"
done
```

---

## 10. Rollback Procedure

If a critical issue is discovered after publishing:

### 10.1 Pull the ISOs from the download page

Update the website download page to remove links to the broken release immediately. Do not leave broken ISOs publicly linked while you investigate.

### 10.2 Assess the scope

- Is the issue in all ISOs or only specific profiles?
- Is it a packaging bug, a configuration bug, or a build system bug?
- Can it be fixed with a point release, or must the release be fully retracted?

### 10.3 For a point release fix

Apply the fix to the relevant layer (`base/`, `editions/`, `flavors/`, or `hardware/`), bump `DISTRO_VERSION` to a patch version (e.g. `1.1.1`), and run the full release process again from Phase 1.

### 10.4 For a full retraction

```bash
# Remove the tag locally and remotely
git tag -d "v${DISTRO_VERSION}"
git push origin ":refs/tags/v${DISTRO_VERSION}"
```

Remove the release from the repository host (GitHub/Forgejo). Remove the files from the mirror. Post a notice explaining the retraction and the timeline for the corrected release.

Do not reuse the version number. If `1.1` was retracted, the corrected release is `1.1.1` or `1.2` - never `1.1` again.

---

## 11. Release Checklist (printable)

Copy this section to a tracking issue or document for each release.

### Phase 1 - Preparation
- [ ] All lint checks pass (`lint-packages.sh`, `check-duplicate-packages.sh`, `check-no-hardcoded-names.sh`, `check-brand-vars-used.sh`)
- [ ] `brand/identity/name.env` reviewed and correct
- [ ] `CHANGELOG.md` updated and reviewed
- [ ] All profiles pass dry-run
- [ ] Working tree is clean (`git status`)

### Phase 2 - Version Bump
- [ ] `DISTRO_VERSION` bumped in `brand/identity/name.env`
- [ ] Expected ISO filenames verified
- [ ] Version bump committed with message `release: bump version to X.Y`

### Phase 3 - Build
- [ ] All release profiles built successfully
- [ ] No `--skip-lint` or `--skip-sign` used
- [ ] All ISOs present in staging directory

### Phase 4 - Verification
- [ ] All checksums verified (`sha256sum -c`, `sha512sum -c`)
- [ ] All GPG signatures verified
- [ ] `/etc/os-release` checked in at least one ISO per edition
- [ ] Smoke test passed on at least `desktop-xfce` and `core`
- [ ] Build manifests show correct version, edition, flavor

### Phase 5 - Sign and Finalise
- [ ] All ISOs signed
- [ ] Combined `SHA256SUMS` file generated and signed

### Phase 6 - Tag and Publish
- [ ]  `dev` merged into `main` (clean fast-forward confirmed)
- [ ] Git tag `v${DISTRO_VERSION}` created and pushed
- [ ] ISOs published to mirror via `publish.sh`
- [ ] Mirror upload verified accessible via curl
- [ ] Container digest verified and retagged (`:DISTRO_VERSION`, `:stable` — §8.3, GHCR public from first release)
- [ ] GitHub/Forgejo release created with changelog and artifacts
- [ ] Website download page updated
- [ ] Download links tested directly

### Phase 7 - Post-Release
- [ ] Release announced
- [ ] `stable` pointer on mirror updated
- [ ] `DISTRO_VERSION` bumped to next dev version and committed
- [ ] Staging directory archived or deleted
- [ ] Build directories cleaned
