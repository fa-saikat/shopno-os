# Container Guide

> How ShopnoOS builds a minimal OCI image and proves its supply chain: intention, mechanics, and why each piece exists.

---

## Table of Contents

1. [Intention — Why a Container at All](#1-intention--why-a-container-at-all)
2. [What It Produces](#2-what-it-produces)
3. [Prerequisites](#3-prerequisites)
4. [Your First Container Build](#4-your-first-container-build)
5. [What the Build Does Internally](#5-what-the-build-does-internally)
6. [Package Model — Subtractive, Not Parallel](#6-package-model--subtractive-not-parallel)
7. [Tagging and Versioning](#7-tagging-and-versioning)
8. [Supply-Chain Evidence (Slices 3–4)](#8-supply-chain-evidence-slices-34)
9. [CI Integration](#9-ci-integration)
10. [Verifying an Image](#10-verifying-an-image)
11. [Troubleshooting](#11-troubleshooting)
12. [What Not to Do](#12-what-not-to-do)

---

## 1. Intention — Why a Container at All

The ISO is the product; the container is the *proving ground*. A full ISO build takes an hour and a privileged live-build toolchain. A container rootfs builds in minutes, rootless, from the same brand identity and package philosophy — which makes it the cheapest place to exercise three things that matter beyond ShopnoOS itself:

- **OCI fluency**: image assembly, registries, digests, tags — the lingua franca of modern deployment, independent of any orchestrator.
- **Supply-chain evidence**: SBOM, vulnerability scanning, keyless signing, and provenance attestation attached to a real artifact you built, not a tutorial's `hello-world`.
- **Feedback speed**: the subtractive package projection, the APT-source assembly, and the keyring handling all get proven in minutes per iteration instead of per hour.

Nothing here replaces the ISO pipeline. If the container workflow vanished tomorrow, every ISO guarantee would stand. That optionality is deliberate (see ADR-008) — it is also what makes the container work safe to experiment in.

## 2. What It Produces

Per run, in `build/container/`:

| Artifact | Contents |
|---|---|
| `shopno-os-<VERSION>-core-<ARCH>-<DATE>.oci.tar` | OCI image tarball (pushable to any registry) |
| `container-manifest.json` | Machine-readable build record: distro identity, profile, package counts (declared/excluded/final), tarball name, image digest |
| `sbom.spdx.json` (CI) | Full ingredient list in SPDX format |
| `grype.sarif` (CI) | Vulnerability findings, machine-readable |

On merge to `dev`, CI additionally pushes `:edge` + `:<short-sha>` tags to GHCR. Release builds add `:<DISTRO_VERSION>` (see §7).

## 3. Prerequisites

```bash
sudo apt update
sudo apt install --no-install-recommends \
    mmdebstrap \
    buildah \
    skopeo \
    jq \
    gpg
```

- No root required for the concepts, but `mmdebstrap` needs privilege where unprivileged user namespaces are unavailable (all hosted CI runners; check with `unshare --user --map-root-user true`). The script tells you which mode it took.
- ~2 GB free disk for the rootfs working tree (removed on exit unless `--keep-rootfs`).
- Network to a Debian mirror plus `deb.jadupc.com` (project repo — see §5).

## 4. Your First Container Build

```bash
# Dry run first: shows package resolution without downloading anything
./scripts/build/build-container.sh --dry-run

# Real build (needs sudo where userns is unavailable)
sudo ./scripts/build/build-container.sh

# Inspect what came out
cat build/container/container-manifest.json | jq .
buildah images  # (local store entry is removed after export; the tarball is the artifact)
```

Expected: ~186 declared → ~58 excluded → ~128 final packages (exact numbers move with the layers; the ratio is what matters).

Clean up exactly like ISO artifacts:

```bash
./scripts/build/clean.sh --container        # confirm-prompted
sudo ./scripts/build/clean.sh --container   # root-owned leftovers need it
```

## 5. What the Build Does Internally

1. **Validate.** Commands present; profile loads; hard guard: edition must be `core`, flavor `none` — desktop cruft has no business in a minimal image, and the guard documents that instead of silently building a bloated one.
2. **Resolve packages.** `profile_package_lists()` (base + core, in order) → strip comments/versions → subtract `container-exclude.txt` patterns → log declared/excluded/final counts. Refuses an empty final set (a vacuous image is a bug, not minimalism). A backstop re-match fails loud if the subtraction loop ever lets a matched package through — it guards loop drift, not pattern coverage (see §6).
3. **Assemble APT sources.** `mmdebstrap` gets a fully explicit world: Debian suite (+ `-updates` per profile flags) and the project repo line mirroring `base/config/archives/jadupc.list`, with two keyrings — the host's `debian-archive-keyring.gpg` via explicit `signed-by` (mmdebstrap runs apt unchrooted against host trust, which is why bare lines verify on Debian hosts and fail on Ubuntu ones), and a build-time dearmored project key. `deb.jadupc.com` 301-redirects to https while a fresh minbase has no CA certs on first update, so TLS verification is scoped off for that host only — authenticity stays enforced via `signed-by` (no credentials cross that wire).
4. **Run mmdebstrap** (`--variant=minbase`, `SOURCE_DATE_EPOCH` exported — same determinism story as the ISO side).
5. **Assemble OCI image** (`buildah bud --timestamp "${SOURCE_DATE_EPOCH}"`, daemonless): generated `Containerfile` (`FROM scratch`, `ADD rootfs.tar /`, five standard `org.opencontainers.image.*` labels from brand + git SHA + SDE date, one vendor label `org.shopno-os.profile`, `CMD ["/bin/bash"]` for debuggability). Rootfs tarball is input-pinned (`--sort=name`, clamped mtimes, fixed ownership); image timestamp pinned to `SOURCE_DATE_EPOCH`. Same-commit double-build measured identical digests on 2026-09-29 (D-1, `scripts/dev/check-container-determinism.sh`), so the claim is: reproducible given a frozen package set. Cross-day equality is not claimed (live mirrors move daily) and package-version drift across days remains expected.
6. **Export + manifest.** `buildah push --digestfile` to an OCI tarball (the digest capture that actually works on local-store images — `inspect` reports no digest field there), then `container-manifest.json` in the `build-manifest.json` shape so tooling reads both uniformly.

## 6. Package Model — Subtractive, Not Parallel

The Golden Rule ("a package lives in exactly one place") still holds: nothing is *declared* in `container-exclude.txt`, only excluded. `base/*` + `editions/core/*` stay the single source of truth; the exclude file is a *projection* onto a different artifact type. New base packages flow into the container by default — the failure mode is inclusion (visible in the SBOM, catchable by gates), never silent drift between competing lists.

The file's own header states its limit honestly: it is incomplete-by-construction and only catches what someone named. The backstop check in the script guards the subtraction *mechanism*; coverage itself is audited against the built image by the content gate (`tests/smoke/test-container-packages.sh`, ADR-009): denylist absence plus critical set plus count band, all artifact-derived, blocking before publish.

Q1, decided: the image ships the ShopnoOS repo (`/etc/apt/sources.list.d/jadupc.list` + keyring at `/usr/share/keyrings/jadupc.gpg`, same URL/suite/components the build itself uses) — baked, not sealed — so derived images install `shopno-os-*` out of the box. Consequence: keyring rotation is an image-rebuild event.

## 7. Tagging and Versioning

One authority, three pointer types — the `publish.sh` `latest`-symlink pattern reapplied to OCI:

| Tag | Moves when | Means |
|---|---|---|
| `:<short-sha>` | Every dev push | Traceability: artifact → exact commit, no lookup |
| `:edge` | Every dev push | Latest known-good, floating |
| `:<DISTRO_VERSION>` | Release flow only | Ties container to ISO identity (`name.env` is the single version authority — no second scheme) |
| `:stable` | Release flow only | Promoted pointer, never rebuilt |

Tags are convenience pointers; verification is always digest-based. `stable` moving under you is expected behavior, mirroring how signatures are never generated from a mutable name. Promotion mechanics (verify-then-retag, local only) live in `docs/release-process.md` §8.3 — CI never mints these tags.

## 8. Supply-Chain Evidence (Slices 3–4)

Each attaches to the digest, in dependency order:

- **SBOM (`syft`, blocking).** No SBOM means nothing downstream has input — a missing SBOM fails the run. SPDX JSON, uploaded as artifact.
- **Scan (`grype`, metric-first).** Base images always carry CVEs; blocking on day one would veto good builds for upstream noise. Table to logs, SARIF + JSON to artifacts (JSON feeds the per-severity summary), promotion to a gate waits on a trusted baseline (ADR-005 pattern, graduation tracked in issue #68).
- **Sign (`cosign`, keyless via GitHub OIDC) + provenance (`attest-build-provenance`, SLSA) + SBOM attestation (`attest-sbom`).** Signs the digest, never the tag. No long-lived credential exists at any point (narrowed ADR-006) — per-run OIDC token plus ephemeral `GITHUB_TOKEN`. The pipeline then verifies both (`cosign verify` + `gh attestation verify`, blocking), so a bad or missing signature fails the run instead of passing silently. Provenance scope, stated plainly: it attests workflow + commit, not a hermetic build — do not present it as SLSA Level 3.

What this deliberately does *not* prove: novel backdoors sail through CVE matching green (the XZ lesson — say it unprompted), and keyless means "no key custody," not "no trust" (Fulcio/Rekor operators remain in the loop).

## 9. CI Integration

`container-build.yml` (ADR-008 — separate file, never folded into `build-iso.yml`):

- PRs (paths-scoped to image inputs: script, denylist, workflow, package lists, core profile, keyring, libs, brand): build + smoke + SBOM + scan in a least-privilege job, **zero registry writes**, `publish` skipped.
- Merge to `dev`: the `publish` job (sole holder of write/OIDC rights) downloads the blocking handoff, pushes `edge`/SHA (digest from the push itself), signs, attests provenance + SBOM, and verifies — in that order, so proof always precedes publication.
- Dispatch: the chosen core-family profile (`inputs.profile`, default core).
- Smoke runtime is docker via a skopeo bridge (`oci-archive:` → `docker-daemon:`), not `buildah run` — the daemon is guaranteed on hosted runners, rootless OCI runtimes are not. The smoke logs the image's apt sources, then asserts both sources work *inside* the artifact (`apt-get update` across Debian + ShopnoOS repo, then install-and-run `hello` — a package guaranteed absent from minbase, so the install genuinely proves something).
- Privilege follows `build.sh`: the mmdebstrap step runs under `sudo` (hosted runners disable unprivileged user namespaces, so rootless is impossible there, not merely slower). Artifacts land root-owned; `clean.sh --container` refuses non-root runs and verifies removal under sudo — the privilege story is one system across both builders, not per-script folklore.
- Uploads: the build→publish handoff is blocking and push-only (1-day retention — the publish job consumes it within minutes); SBOM/SARIF evidence uploads are `continue-on-error` with 7-day retention: preservation must never veto verdicts (artifact quota and network health are environmental, never code defects). Key evidence additionally lands in `$GITHUB_STEP_SUMMARY`, which costs no storage and survives quota exhaustion.

Full trigger/stage reference lives in `docs/ci-cd.md` §2.3 — this guide covers intent and mechanics, that document covers the deployed pipeline.

## 10. Verifying an Image

```bash
# Identity continuity: the digest the build recorded vs what the registry serves
test "$(jq -r .output.digest container-manifest.json)" = "$(skopeo inspect docker://ghcr.io/<org>/shopno-os:edge --format '{{.Digest}}')" && echo IDENTITY_OK
# (Same-run pairing only. Cross-run equality is a reproducibility claim, not an identity check.)

# Contents: labels carry identity without pulling layers
skopeo inspect docker://ghcr.io/<org>/shopno-os:edge | jq '.Labels'
```

```bash
# Signature: keyless, bound to digest by Fulcio/Rekor - needs nothing of yours
cosign verify ghcr.io/<org>/shopno-os:edge \
  --certificate-identity-regexp 'https://github.com/<org>/shopno-os.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Attestations: SLSA provenance + SBOM, verified against repo identity
gh attestation verify oci://ghcr.io/<org>/shopno-os:edge --repo <org>/shopno-os
```
(Replace `<org>` throughout. The identity regexp scopes trust to workflows in your repo — without it, any GitHub workflow's signature would verify.)

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Unable to locate package shopno-os-*` | Project repo source/keyring missing from mmdebstrap's APT world | Check Step 2 logs: sources list assembled, key dearmored, signed-by present |
| `NO_PUBKEY` on Debian suites | Host keyring absent or unsigned-by lines dropped | Install `debian-archive-keyring`; never remove the explicit `signed-by` |
| Cert verification on first update | Scoped `Verify-Peer=false` regressed or apt ignored host scoping | See the NOTE at the mmdebstrap invocation; escalate to build-time global as documented there |
| `Permission denied` creating rootfs | User namespaces unavailable, ran without sudo | Re-run with `sudo` (same as `build.sh`); clean leftovers with `sudo clean.sh --container` |
| Empty digest in manifest | Digest capture regressed | The `--digestfile` + empty-guard is load-bearing; do not "simplify" to `inspect` (proven broken on local-store images) |
| `FINAL` count collapses | Denylist over-match (e.g. a broad new glob) | Review `container-exclude.txt` diff; dry-run shows per-pattern attribution at debug log level |
| Checksum verify fails with "no such file" | Downloaded tarball renamed via `-o` while the checksums file references the release filename — verification binds to bytes-on-disk under their published name | Download under the remote filename; never rename before `sha256sum -c` (bitten once on syft/grype installs, hence this row) |

## 12. What Not to Do

- Don't reuse the live-build chroot as the rootfs source (`live-boot`/`live-config` state is meaningless outside live boot — previously proven harmful).
- Don't add a parallel package list for containers (duplicates the Golden Rule's nightmare; extend the denylist instead).
- Don't sign or verify tags (digests only — tags move by design).
- Don't put long-lived registry credentials in CI (ephemeral `GITHUB_TOKEN` + OIDC is the whole point; a static credential would reopen ADR-006).
- Don't gate PRs on the scan until a trusted baseline exists (an always-red metric trains ignore).
- Don't build desktop/gaming variants without their own package-set proposal (the core-only guard exists to force that conversation, not to be deleted quietly).
