# Phase 4 — Implementation Limitations & Remediation Plan

> Scope: `scripts/build/build-container.sh`, `scripts/build/container-exclude.txt`, `.github/workflows/container-build.yml`, `scripts/build/clean.sh` (container additions), `docs/container-guide.md`, `docs/ci-cd.md`, ADR-006/007/008.
> Basis: review of the files as uploaded on 2026-09-28. Items marked **(verify)** are inferences from reading the code, not observed behavior. Confirm them before acting.

---

## 1. Summary

Phase 4 delivers a working build → smoke → SBOM → scan → push → sign → attest chain with sound individual decisions (scoped `Verify-Peer=false` backed by `signed-by`, `--digestfile`, docker-daemon smoke runtime, no signing of PR builds, SBOM as a blocking step, scan as a metric).

The limitations below are mostly about **ordering, scoping, and claims**, not missing tools:

| Theme | Problem in one line |
|---|---|
| Trust ordering | Image is published before it is proven, and can be stranded unsigned |
| Coverage | CI does not run when the package inputs change |
| Privilege | Write/OIDC permissions are workflow-wide, not confined to the publish step |
| Claims vs. reality | "Deterministic", "smoke proves the APT world", "PR can never leak" are stronger than what is implemented |
| Verification | Nothing verifies the signature/attestation that was just produced |
| Content gate | No artifact-absence check; no growth ceiling; Tier B still open |

---

## 2. Limitation Register

Severity: **H** = undermines a trust claim or breaks the pipeline's purpose · **M** = real defect, bounded impact · **L** = hygiene/consistency.

### 2.1 Workflow

| ID | Sev | Limitation | Evidence | Impact |
|---|---|---|---|---|
| W1 | H | Push to GHCR happens **before** SBOM, scan, sign, attest | Step order in `container-build.yml` | A failure after push leaves `:edge` / `:<sha>` public and unsigned |
| W2 | H | `cancel-in-progress: true` also cancels `push` runs | `concurrency` block | A newer push can cancel an older run between push and sign, stranding an unsigned image |
| W3 | H | Path filter lists only the script, the denylist, and the workflow | `on.*.paths` | Changes to `base/`, `editions/core/`, profile, jadupc key, `scripts/lib/`, `brand/` never trigger a build; `:edge` stops tracking `dev` |
| W4 | H | `packages/id-token/attestations: write` granted at workflow level; build job (runs `sudo` on repo code) holds OIDC-minting rights | `permissions` block | Only `if:` guards protect PR runs; `ci-cd.md` claim "a PR can never leak an image even on misconfiguration" overstates |
| W5 | M | Digest is re-read from the mutable `:edge` tag after push | `Resolve pushed digest` step | Race with a concurrent push can sign the wrong digest |
| W6 | H | No `cosign verify` / `gh attestation verify` in CI | Absent | A bad or missing signature cannot fail the pipeline |
| W7 | M | No assertion that manifest digest == pushed digest | Absent | Two "digests" for one image possible if skopeo recompresses layers **(verify)** |
| W8 | M | Smoke test installs `curl`, which is already in the image | `curl` is in base `shopno-os-utils` per `package-ownership.md` | Only `apt-get update` is actually exercised |
| W9 | M | Smoke comment claims the project repo + keyring work inside the artifact | Jadupc source/keyring live only in build-time `WORKDIR` | Claim not backed by the artifact **(verify with `cat /etc/apt/sources.list*` in the image)** |
| W10 | L | `workflow_dispatch.inputs.profile` is never used | Build step hardcodes `shopno-os-core` | Docs claim "any core-family profile" |
| W11 | L | `IMAGE_NAME: fa-saikat/shopno-os` hardcoded | `urls.env` says `JaduPC/shopno-os` | Breaks silently if repo moves; violates no-hardcode rule |
| W12 | L | Actions pinned by tag, tools pinned by checksum | `@v4`, `@v3`, `@v2` | Inconsistent with ADR-004 principle |
| W13 | L | Grype metric can never go orange; no graduation rule or tracking issue | `continue-on-error` + exit 0 | Violates ADR-005's "promotion rule written at introduction" |

### 2.2 Script

| ID | Sev | Limitation | Evidence | Impact |
|---|---|---|---|---|
| S1 | H | Image `created` timestamp is wall-clock | `buildah bud` has no `--timestamp` | Digest differs every run regardless of pinned tar |
| S2 | M | `BUILD_DATE` computed before `SOURCE_DATE_EPOCH` is exported | Line ~97 vs ~270 | Tarball name/manifest date ≠ `created` label date; differs from `build.sh` ordering |
| S3 | M | Package versions come from live mirror + mutable project repo | `mmdebstrap` against `mirror.sg.gs` and `deb.jadupc.com` | Same commit, different day ⇒ different content; "reproducible" cannot be claimed |
| S4 | M | Jadupc URL and suite hardcoded | Lines ~256, ~279 | Second copy of `jadupc.list` (Golden Rule); likely flagged by `check-no-hardcoded-names.sh` **(verify by running it)** |
| S5 | M | `load_secrets` sourced in a script that never uses secrets | Lines ~44–45, ~86 | On dev machines, credentials exported to all child processes, including package maintainer scripts **(verify env pass-through)** |
| S6 | M | No security pocket; script ignores `LB_SECURITY`; core profile has `LB_SECURITY="false"` | `sources.list` assembly | Grype findings include fixable CVEs; image users may lack security updates **(verify final sources)** |
| S7 | L | `image.source` uses `DISTRO_WEBSITE` | Label block | Should be repo URL (`URL_SOURCE`); GHCR uses it to link package to repo |
| S8 | L | `image.version` includes codename `(uday)` | Label block | Diverges from tag `:2.2` and ADR wording |
| S9 | L | Interrupted build between `bud` and `rmi` leaves a local image | `_cleanup` only removes WORKDIR | Manual `clean.sh --container` needed |

### 2.3 Design / Gate

| ID | Sev | Limitation | Impact |
|---|---|---|---|
| D1 | H | No artifact-absence check on the built image | Denylist coverage is unaudited; the "SBOM/gate is the backstop" claim has no gate |
| D2 | M | No growth ceiling | New base packages flow into the published image silently |
| D3 | M | Tier B (lvm2, mdadm, ufw, openssh-server, openvpn, nmap, tcpdump, cron, rsyslog…) undecided | "Minimal base" ships sshd and network scanners; inflates CVE metric |
| D4 | M | Release-tag promotion (`:<DISTRO_VERSION>`, `stable`) is documented but has no implementation or runbook | Those tags cannot currently exist |
| D5 | L | SLSA provenance claim is unqualified | Build is not hermetic; same job holds signing rights; do not present as L3 |
| D6 | L | GHCR package is private by default | "Verify with nothing of yours" fails for strangers until visibility is public |
| D7 | L | Self-hosted runner (#46) + `sudo` build on `pull_request` | Would be arbitrary code execution on persistent hardware for fork PRs |

### 2.4 Documentation drift

| ID | Location | Issue |
|---|---|---|
| X1 | `ci-cd.md` §2.3 | Says "rootless mmdebstrap" (CI runs it under `sudo`); pipeline listing omits smoke/sign/attest; says syft/grype in install deps (separate step) |
| X2 | `ci-cd.md` §9 | Says slice 4 "not yet built"; YAML contains it. One is wrong |
| X3 | `architecture.md` tree | Still lists `release.yml` while §13 says deliberately not built |
| X4 | ADR-008 | Does not record: scoped `Verify-Peer=false`, `sudo` instead of rootless, docker-daemon smoke, `attest-sbom`, denylist-incomplete consequence |
| X5 | `container-guide.md` | "Deterministic" wording; §8 omits `attest-sbom`; no provenance-limits sentence |

---

## 3. Open Decisions (need your call before the related step)

| # | Decision | Affects | Recommendation |
|---|---|---|---|
| Q1 | Should the image ship with the project repo configured in `/etc/apt`? | W9 | Decide from intended use: if derived images will `apt install shopno-os-*`, yes; otherwise no. Write the answer in the guide either way |
| Q2 | Security pocket for containers? | S6 | Enable regardless of `LB_SECURITY`; a container base without security updates undermines the supply-chain story |
| Q3 | Tier B: denylist, keep, or ceiling-only? | D3 | Deny "no daemons, no privileged-hardware tooling" as one rule; if exclusions approach half the source list, switch to a small allow-list |
| Q4 | Has sign/attest actually run on a real `dev` push? | W1, W6, X2 | If not, treat slice 4 as unproven until step A7 passes |
| Q5 | Where does `:<DISTRO_VERSION>` / `stable` promotion run? | D4 | Local, per ADR-006 (verify digest, then retag, no rebuild) |

---

## 4. Remediation Plan

Effort: **S** ≈ under 1 h · **M** ≈ 1–3 h · **L** ≈ half day+. Commit prefixes follow `docs/git-guide.md`.

### If time is short (minimum credible path)

Do **A1 → A5**, **A7**, **B1**, **B2**, **B3**, **F1**, **F2**. This fixes trust ordering, coverage, privilege, verification, and the two claims most likely to be challenged. Everything else can be listed as "known limitations" (this document is the artifact for that).

---

### Phase A — Workflow trust fixes (highest value, workflow-only)

**A1. Complete the path filters** (W3) — S · `ci:`-style change, use `build:`
- Add to both `pull_request` and `push` path lists:
  ```yaml
  - 'base/package-lists/**'
  - 'editions/core/package-lists/**'
  - 'profiles/shopno-os-core/**'
  - 'base/config/archives/**'
  - 'scripts/lib/**'
  - 'brand/**'
  ```
- Done when: a PR touching only `base/package-lists/shopno-os-utils.list.chroot` triggers the workflow.

**A2. Make cancellation PR-only** (W2) — S
```yaml
concurrency:
  group: container-build-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```
- Done when: two quick pushes to `dev` both run to completion.

**A3. Split into `build` and `publish` jobs** (W4) — M
- Top-level `permissions: contents: read` only.
- `build` job: `contents: read`; builds, smoke-tests, generates SBOM, scans; uploads tarball + manifest + SBOM as artifacts.
- `publish` job: `needs: build`, `if: github.event_name == 'push'`, permissions `contents: read`, `packages: write`, `id-token: write`, `attestations: write`; downloads artifacts; pushes; signs; attests; verifies.
- The **handoff upload must be blocking** (publish depends on it). Only the evidence upload (SARIF/summary copies) stays `continue-on-error`.
- Done when: a PR run shows no step with write permissions, and the publish job is skipped on PRs.

**A4. Reorder: prove, then publish** (W1) — S (part of A3)
Order inside the pipeline: build → smoke → SBOM (blocking) → scan (metric) → **publish job**: push → sign → attest → verify.
- Done when: a deliberately failing SBOM step leaves nothing in GHCR.

**A5. Take the digest from the push itself** (W5) — S
```bash
skopeo copy --digestfile digest.txt \
  "oci-archive:${TARBALL}" "docker://${IMAGE}:${SHORT_SHA}"
DIGEST="$(cat digest.txt)"
skopeo copy "docker://${IMAGE}@${DIGEST}" "docker://${IMAGE}:edge"
```
- Done when: the signed digest is provably the one just pushed, independent of `:edge`.

**A6. Assert build-record ↔ registry identity** (W7) — S
```bash
test "$(jq -r .output.digest container-manifest.json)" = "${DIGEST}" \
  || { echo "manifest digest != pushed digest"; exit 1; }
```
- If this fails, skopeo re-encoded the image on push. Options: keep both digests in the manifest (`output.build_digest`, `output.registry_digest`) and document why, or push with `buildah push` to `docker://` so the digest is preserved. Record the outcome in the guide.

**A7. Verify what was signed** (W6) — M
In the publish job, after sign/attest:
```bash
cosign verify "${IMAGE}@${DIGEST}" \
  --certificate-identity-regexp "^https://github.com/${GITHUB_REPOSITORY}/\.github/workflows/container-build\.yml@refs/heads/dev$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

GH_TOKEN="${{ github.token }}" gh attestation verify "oci://${IMAGE}@${DIGEST}" --repo "${GITHUB_REPOSITORY}"
```
- Done when: the job fails if either verification fails. Test once by pointing verify at a wrong identity and confirming a red run (keep the run URL as evidence).

**A8. Fix the smoke test** (W8, W9) — S
```bash
docker run --rm "${TAG}" bash -c \
  'apt-get update && apt-get install -y --no-install-recommends hello && hello'
```
- Add `docker run --rm "${TAG}" cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null` to the log, then apply Q1.
- Rewrite the step comment to say only what the test proves.

**A9. Small workflow cleanups** (W10, W11) — S
- `IMAGE_NAME`: compute `IMAGE="ghcr.io/${GITHUB_REPOSITORY,,}"` in a step.
- Wire `inputs.profile` through `env:` (never inline `${{ }}` in `run:`), or remove the input and fix `ci-cd.md`.

---

### Phase B — Script fixes

**B1. Remove `load_secrets`** (S5) — S · `build:`
- Delete the `source secrets.sh` and `load_secrets` lines. Nothing in the script consumes them.
- Done when: `env | grep OS_` inside a `--keep-rootfs` run shows no credential variables.

**B2. Export `SOURCE_DATE_EPOCH` before deriving dates** (S2) — S
- Move the export block above `BUILD_DATE="$(iso_build_date)"`, matching `build.sh`.
- Done when: tarball name date equals the `created` label date on a build of an older commit.

**B3. Pin the image timestamp** (S1) — S
```bash
_run buildah bud --timestamp "${SOURCE_DATE_EPOCH}" --format oci ...
```
- **(verify)** flag support on the runner's buildah (`buildah bud --help`). If unsupported, install a newer buildah or set `--source-date-epoch`.

**B4. Read the project repo definition from `jadupc.list`** (S4) — M
- Parse the `deb` line from `base/config/archives/jadupc.list`, inject `signed-by=` for the dearmored key, and derive the host for the scoped `Verify-Peer` option from the same line.
- Run `tests/lint/check-no-hardcoded-names.sh` before and after; expect the findings to disappear.

**B5. Security pocket** (S6) — S–M, after Q2
- Add `trixie-security` (security.debian.org) with the explicit `signed-by` keyring to the assembled sources, independent of `LB_SECURITY`.
- Check the final image's own apt sources and make them deliberate (mirror choice, `-updates`, `-security`).
- Done when: `apt-get -s upgrade` inside the image can see the security suite, and the grype count is re-baselined.

**B6. Labels** (S7, S8) — S
- `image.source` ← `${URL_SOURCE}`; add `image.url` ← `${DISTRO_WEBSITE}`; optionally `image.vendor` ← `${DISTRO_VENDOR}`.
- `image.version` ← `${DISTRO_VERSION}` only; keep the codename in a vendor label (`org.shopno-os.codename`) if wanted.

**B7. Clean up local image on failure** (S9) — S
- In `_cleanup`, add `buildah rmi "${IMAGE_REF}" >/dev/null 2>&1 || true` guarded by the variable being set.

---

### Phase C — Content gate (closes the "who is watching the denylist" gap)

**C1. Decide Tier B** (D3) — M · decision, then `build:`
- Apply Q3. Extend `container-exclude.txt` with commented groups per rule. Re-run `--dry-run` and record the new declared/excluded/final counts.

**C2. Artifact-absence + critical + ceiling test** (D1, D2) — M–L · `tests:`
- New `tests/smoke/test-container-packages.sh`, modeled on ADR-003 (artifact-derived truth):
  1. Load the OCI tarball into docker (skopeo bridge, already in the workflow).
  2. `docker run --rm IMAGE dpkg-query -W -f='${Package}\n'` → installed set.
  3. Fail if any installed package matches a `container-exclude.txt` pattern.
  4. Fail if any `critical_packages` entry is missing.
  5. Fail if the count is outside `[total_min, total_max]`.
- New fixture `tests/fixtures/expected-container-packages.json`:
  ```json
  {
    "schema_version": "1",
    "profiles": {
      "shopno-os-core": {
        "total_min": 0,
        "total_max": 0,
        "critical_packages": ["bash", "apt", "dpkg", "curl"],
        "validated_against_real_image": false
      }
    }
  }
  ```
  Seed `total_min` ≈ 85% and `total_max` ≈ 115% of a real observed count, then set `validated_against_real_image: true` (same discipline as the ISO fixture).
- Wire into the `build` job as a **blocking** step (deterministic, no virtualization). Cross-check against the SBOM package list as a second source.
- Write **ADR-009** (short): floor for ISOs because loss is the risk; ceiling for container bases because growth is the risk.

---

### Phase D — Determinism: prove it or scope the claim

**D-1. Double-build test** (S1–S3) — M
```bash
sudo ./scripts/build/build-container.sh --output-dir /tmp/a
sudo ./scripts/build/build-container.sh --output-dir /tmp/b
diff <(jq -S .output.digest /tmp/a/container-manifest.json) \
     <(jq -S .output.digest /tmp/b/container-manifest.json)
```
- If digests differ: `diffoscope /tmp/a/*.oci.tar /tmp/b/*.oci.tar`, categorize the differences (timestamps, package versions, ordering), fix what is fixable, and publish the report either way.
- If they match on the same day but you expect drift across days (S3), state that explicitly: reproducible **given a frozen package set**, not across mirror updates.
- Update `container-guide.md` wording to match the measured result ("input-pinned" vs "reproducible").

---

### Phase E — Release path for `:<DISTRO_VERSION>` and `stable`

**E1. Document and script the promotion** (D4) — M · `docs:` (+ `scripts:` if scripted)
- Add to `docs/release-process.md` after publishing ISOs:
  ```bash
  # verify the exact digest first, then retag with no rebuild
  cosign verify "${IMAGE}@${DIGEST}" --certificate-identity-regexp ... --certificate-oidc-issuer ...
  skopeo copy "docker://${IMAGE}@${DIGEST}" "docker://${IMAGE}:${DISTRO_VERSION}"
  skopeo copy "docker://${IMAGE}@${DIGEST}" "docker://${IMAGE}:stable"
  ```
- Runs locally with a short-lived GitHub token, consistent with ADR-006 (no long-lived credential in CI).
- The signature follows the digest, so retagging keeps it valid. State that in the guide.

**E2. Make the package public** (D6) — S · one-time manual step
- GHCR → package settings → visibility. Note it in the guide's verification section.

---

### Phase F — Documentation and ADR corrections

**F1. Correct drift** (X1–X3, X5) — S · `docs:`
- `ci-cd.md` §2.3: remove "rootless"; list all real steps in order; move syft/grype to the correct step; fix §9 to match the YAML (or mark slice 4 "unproven until A7 passes" if Q4 is "no").
- `architecture.md`: remove `release.yml` from the tree or annotate "not built (ADR-006)".
- `container-guide.md`: reword determinism (D-1 outcome), add `attest-sbom` to §8, add the provenance-limits sentence (D5).

**F2. Amend ADR-008** (X4) — S · `docs:`
Append an **Amended** block (same style as ADR-006) recording:
- scoped `Verify-Peer=false` for the project repo host, justified by `signed-by`;
- privileged (`sudo`) build on hosted runners instead of rootless;
- docker-daemon smoke runtime;
- SBOM attestation in addition to provenance;
- denylist incompleteness and the artifact-absence gate as the real backstop (Phase C).

**F3. Grype graduation rule** (W13) — S
- Write it in the workflow comment and open a tracking issue: baseline for N runs, then fail on Critical-with-fix. Log run URLs in the issue, as done for the boot gate (ADR-005).

---

### Phase G — Hardening extras (do when time allows)

| Step | Change | Addresses |
|---|---|---|
| G1 | Pin third-party actions by commit SHA; add Dependabot for `github-actions` | W12 |
| G2 | Add a note to `container-build.yml` and `docs/ci-cd.md`: self-hosted runners (#46) must not run `pull_request` from forks | D7 |
| G3 | Upload SARIF to code scanning if you want findings history (needs `security-events: write` on the publish/scan job only) | W13 |
| G4 | Record image size and package count in `$GITHUB_STEP_SUMMARY` on every run | Metrics trend |

---

## 5. Verification Checklist (definition of done for Phase 4)

- [ ] A PR touching only `base/package-lists/*` triggers the container workflow (A1)
- [ ] Two rapid pushes to `dev` both complete; no stranded unsigned tag (A2)
- [ ] PR runs show no write permissions; publish job skipped (A3)
- [ ] Forced SBOM failure leaves nothing in GHCR (A4)
- [ ] CI fails on a wrong-identity `cosign verify` (A7) — run URL saved
- [ ] `manifest digest == registry digest` asserted or the difference documented (A6)
- [ ] Smoke test installs an absent package (A8)
- [ ] `env` inside the build shows no credentials (B1)
- [ ] `check-no-hardcoded-names.sh` passes on the script (B4)
- [ ] Artifact-absence test green; a deliberately removed denylist entry turns it red (C2) — run URL saved
- [ ] Double-build result recorded in the guide (D-1)
- [ ] `docs/ci-cd.md`, `architecture.md`, `container-guide.md`, ADR-008 match the YAML (F1, F2)

---

## 6. What You Can Honestly Claim

| Claim | Today | After the plan |
|---|---|---|
| Container image built from the same package sources as the ISO, via subtractive projection with a self-checking loop | Yes | Yes |
| Keyless-signed, SBOM-attested, provenance-attested image on GHCR | Only if slice 4 has run on a real push (Q4) | Yes, with CI verification (A7) |
| Signature is verified in the pipeline | No | Yes |
| Denylist coverage is audited against the built artifact | No | Yes (C2) |
| Build is reproducible | No; say "input-pinned (tar, label)" | As measured in D-1, scoped to a frozen package set |
| CI proves every change that can alter the image | No (W3) | Yes (A1) |
| Provenance is SLSA Level 3 | No; do not say it | Still no; say "attests workflow + commit" |

The strongest interview line this plan produces is not the tool list. It is: *"I found that my pipeline published before proving, fixed the ordering and privilege boundary, added verification that can fail, and measured what reproducibility I actually had."*
