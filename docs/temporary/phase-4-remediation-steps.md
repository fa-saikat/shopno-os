# Phase 4 Remediation — Step-by-Step Execution Plan

> Source of truth: `docs/temporary/phase-4-implementation-limitation.md`
> (committed at `812df389`, NOT untracked — verified Sep 28).
> Sequence agreed: A1 → A3+A4+A5+A7 as one unit → B1+B2+B3 →
> F1+F2 → C1+C2+D-1 → B4–B7, E, G.
> Workflow: start one step → implement → validate → mark done below →
> move to next. Never batch completions.

## Working conventions (non-negotiable)

- `dev` authoritative; PRs gate to it; `main` fast-forward + tags only.
- Assistant edits + validates, hands commit text. User executes all git
  operations. Never push/merge/delete branches/rewrite pushed history.
- Commit subjects imperative with layer prefixes (`ci:`/`build:`/`tests:`/
  `docs:`/`fix:`). Bodies hard-wrapped ≤80 cols. Never `git add -A`;
  never commit session files (`*session*.md`, `directory-structure.md`,
  `/tmp/*`, `devops-integration-plan-progress-review.json`).
- CI-trigger / build-logic / credential changes: propose BEFORE modifying.
  Docs-only fixes may proceed directly.
- Evidence over reasoning: run `actionlint` / checker / test; mark
  `(verify)` honestly when a check cannot run here.
- Statuses: `[ ]` pending, `[/]` in progress, `[x]` done (validated).

## Verified divergences carried into this plan

- `build-iso.yml` upload has NO `continue-on-error` (only `if: always()`).
- Container `push:` is ALSO paths-scoped (same 3 paths) — W3 worse than briefed.
- Dispatch `inputs.profile` is dead (build step hardcodes `shopno-os-core`).
- `build-container.sh` has two "Step 2" headers; digest `--digestfile` OK.
- `actionlint` NOT installed on this machine (verify pending).

---

## Phase A — Workflow trust fixes (workflow-only)

- [ ] **A1. Complete the path filters (W3)** — S · `ci:` (use `build:` per audit)
  - Add to BOTH `pull_request` and `push` paths in `container-build.yml`:
    `base/package-lists/**`, `editions/core/package-lists/**`,
    `profiles/shopno-os-core/**`, `base/config/archives/**`,
    `scripts/lib/**`, `brand/**`. All 6 verified to exist.
  - Validate: `actionlint` + YAML parse; done when PR touching only
    `base/package-lists/shopno-os-utils.list.chroot` triggers workflow.
  - Status: [/] proposed, awaiting approval to apply on
    `ci/container-path-filter`.
- [ ] **A3+A4+A5+A7. Trust reorder as ONE unit (W1/W2/W4/W5 + W6)** — M
  - A2 paired here (cancel window IS race window): `cancel-in-progress`
    becomes `${{ github.event_name == 'pull_request' }}`.
  - Split `build` / `publish` jobs; top-level `permissions: contents: read`
    only; `publish` gets `packages/id-token/attestations: write`.
  - Order: build → smoke → SBOM (blocking) → scan (metric) → publish job:
    push → sign → attest → verify. Handoff upload blocking; only evidence
    upload stays `continue-on-error`.
  - A5: digest from `skopeo copy --digestfile`, never re-read `:edge`.
  - A7: `cosign verify` + `gh attestation verify` in-pipeline, must fail red.
  - Validate: `actionlint`; PR run shows no write perms + publish skipped;
    forced SBOM failure leaves GHCR empty; wrong-identity verify goes red
    (save run URL).
- [ ] **A6. Assert manifest ↔ registry identity (W7)** — S · experiment decides
  - `test "$(jq -r .output.digest container-manifest.json)" = "${DIGEST}"`.
  - If fail: keep both digests + document, or push via `buildah push`.
- [ ] **A8. Fix smoke test (W8/W9)** — S (needs Q1 decision first)
  - Install absent package (`hello`), log artifact apt sources, rewrite comment
    to claim only what is proven.
- [ ] **A9. Small cleanups (W10/W11)** — S
  - `IMAGE_NAME` from `${GITHUB_REPOSITORY,,}`; wire or remove dead
    `inputs.profile`.

## Phase B (hygiene first) — Script fixes

- [ ] **B1. Remove `load_secrets` (S5)** — S · `build:`
  - Delete `source secrets.sh` + `load_secrets`. Validate: `env | grep OS_`
    clean in `--keep-rootfs` run.
- [ ] **B2. Export `SOURCE_DATE_EPOCH` before dates (S2)** — S
  - Move export above `BUILD_DATE`. Validate: tarball name date == label date
    on older commit.
- [ ] **B3. Pin image timestamp (S1)** — S
  - `buildah bud --timestamp "${SOURCE_DATE_EPOCH}"`. Validate: `buildah bud
    --help` on runner (verify flag present per brief).

## Phase F — Docs / ADR corrections

- [ ] **F1. Correct drift (X1–X3, X5)** — S · `docs:`
  - `ci-cd.md` §2.3 + §9, `architecture.md` tree, `container-guide.md` §8.
- [ ] **F2. Amend ADR-008 (X4)** — S · `docs:`
  - Appended Amended block: Verify-Peer scope, sudo, docker-daemon smoke,
    attest-sbom, denylist backstop.

## Phase C + D — Content gate + determinism

- [ ] **C1. Decide Tier B (D3, needs Q3)** — M · decision then `build:`
- [ ] **C2. Artifact-absence + critical + ceiling test (D1/D2)** — M–L · `tests:`
  - New `tests/smoke/test-container-packages.sh` + fixture
    `expected-container-packages.json`; blocking step. Validate: green run +
    red run on deliberately removed denylist entry (save URLs). ADR-009.
- [ ] **D-1. Double-build test (S1–S3)** — M
  - Two builds → diff digests → `diffoscope` if differ; record outcome in guide.
    Reword "deterministic" to measured result.

## Deferred (in order)

- [ ] **B4. Read repo from `jadupc.list` (S4)** — M (lint already passes; Golden
  Rule only)
- [ ] **B5. Security pocket (S6, needs Q2)** — S–M
- [ ] **B6. Labels (S7/S8, verify `URL_SOURCE` first)** — S
- [ ] **B7. `rmi` on failure (S9)** — S
- [ ] **E1+E2. Release promotion runbook + GHCR visibility (D4/D6)** — M+S
- [ ] **F3. Grype graduation rule (W13)** — S + tracking issue
- [ ] **G1–G4. Hardening extras (W12/D7/W13/metrics)** — as time allows

## Definition of done (from audit §5)

A1 PR-only path change triggers build; rapid pushes both complete; PR shows
no write perms; SBOM failure leaves GHCR empty; wrong-identity verify red;
manifest == registry digest asserted; smoke installs absent package; no creds
in env; hardcoded-names checker passes; absence test green + red on sabotage;
double-build recorded; docs match YAML.

## Open decisions blocking steps (audit §3)

Q1 image apt sources (blocks A8) · Q2 security pocket (blocks B5) ·
Q3 Tier B (blocks C1) · Q4 sign/attest run on real push? (run UI) ·
Q5 `:DISTRO_VERSION`/`stable` promotion local (blocks E1).
