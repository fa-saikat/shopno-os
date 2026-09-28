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
- `actionlint` validated via /tmp/opencode 1.7.7 (not preinstalled).

---

## Phase A — Workflow trust fixes (workflow-only)

- [x] **A1. Complete the path filters (W3)** — S · `ci:` (use `build:` per audit)
  - Add to BOTH `pull_request` and `push` paths in `container-build.yml`:
    `base/package-lists/**`, `editions/core/package-lists/**`,
    `profiles/shopno-os-core/**`, `base/config/archives/**`,
    `scripts/lib/**`, `brand/**`. All 6 verified to exist.
  - Validate: `actionlint` + YAML parse; done when PR touching only
    `base/package-lists/shopno-os-utils.list.chroot` triggers workflow.
  - Status: [x] done — YAML parse OK, actionlint 1.7.7 clean.
    Evidence: fix PR #61 (merged as fb09a451, container job success
    despite quota-blocked upload, by design); trigger proof PR #62
    (touched only base/package-lists, container leg fired, closed
    unmerged).
- [x] **A3+A4+A5+A7. Trust reorder as ONE unit (W1/W2/W4/W5 + W6)** — M
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
  - Status: [x] implemented, push-half proof BLOCKED on quota recovery —
    tracked in issue #64. Merge run 36392254792: build proof green
    (SBOM 648 pkgs, grype 1979), handoff blocked by exhausted quota,
    publish skipped fail-closed (nothing pushed/unsigned). Re-run after
    recalc proves push/sign/attest/verify; A7 negative test still owed.
- [x] **A6. Assert manifest ↔ registry identity (W7)** — S · experiment decides
  - `test "$(jq -r .output.digest container-manifest.json)" = "${DIGEST}"`.
  - If fail: keep both digests + document, or push via `buildah push`.
  - Status: [x] implemented, merged as 9defa181 (PR #67) — PR proof:
    build green, publish skipped. Executes on the first push with a
    working handoff (quota-gated, like #64).
- [x] **A8. Fix smoke test (W8/W9)** — S (needs Q1 decision first)
  - Install absent package (`hello`), log artifact apt sources, rewrite comment
    to claim only what is proven.
  - Status: [x] done, merged as e304e55d (PR #66) — CI round 2 green:
    `hello` installed+ran, both sources updating (scrub + certs proven).
    SBOM baseline shifts +1 (`ca-certificates`, expect ~649).
- [x] **A9. Small cleanups (W10/W11)** — S
  - `IMAGE_NAME` from `${GITHUB_REPOSITORY,,}`; wire or remove dead
    `inputs.profile`.
  - Status: [x] done, merged as 1e975650 (PR #65) — IMAGE derived
    per-job (6 refs), PROFILE wired with core default. actionlint clean.
    PR proof: build green, publish skipped. Runtime proof on next push.

## Phase B (hygiene first) — Script fixes

- [x] **B1. Remove `load_secrets` (S5)** — S · `build:`
  - Delete `source secrets.sh` + `load_secrets`. Validate: `env | grep OS_`
    clean in `--keep-rootfs` run.
  - Status: [x] done, merged as 1e975650 (PR #65) — grep confirms zero
    other secrets consumption; `--dry-run` green; PR build green.
    Full `env` proof needs a real build (verify).
- [x] **B2. Export `SOURCE_DATE_EPOCH` before dates (S2)** — S
  - Move export above `BUILD_DATE`. Validate: tarball name date == label date
    on older commit.
  - Status: [x] move done, merged as 1e975650 (PR #65) — ordering
    hygiene only. CORRECTION: `iso_build_date` (common.sh) is wall-clock
    and ignores SDE, so the move alone cannot equalize the dates. True
    agreement needs the shared helper to honor SDE — separate proposal,
    ISO-affecting, not smuggled in here.
- [x] **B3. Pin image timestamp (S1)** — S
  - `buildah bud --timestamp "${SOURCE_DATE_EPOCH}"`. Validate: `buildah bud
    --help` on runner (verify flag present per brief).
  - Status: [x] done, merged as 1e975650 (PR #65) — flag confirmed on
    local buildah 1.39.3 AND on the CI runner (PR build ran `bud`
    green, resolving the runner-version verify). Digest stability still
    owed a double-build measurement (D-1).

## Phase F — Docs / ADR corrections

- [x] **F1. Correct drift (X1–X3, X5)** — S · `docs:`
  - `ci-cd.md` §2.3 + §9, `architecture.md` tree, `container-guide.md` §8.
  - Status: [x] done — §2.3 rewritten to two-job reality (sudo, split
    jobs, verify live, slice 4 + issue #64); §1 lint paths-ignore noted;
    §3 filter list + least-privilege claim corrected; tree drops
    `release.yml`, gains `container-build.yml`; guide §§5/8/9 match YAML
    (timestamp, attest-sbom, provenance limits, handoff retention).
- [x] **F2. Amend ADR-008 (X4)** — S · `docs:`
  - Appended Amended block: Verify-Peer scope, sudo, docker-daemon smoke,
    attest-sbom, denylist backstop.
  - Status: [x] done, same style as ADR-006 amendment, dated 2026-09-28.

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

- [x] **B4. Read repo from `jadupc.list` (S4)** — M (lint already passes; Golden
  Rule only)
  - Status: [x] done on `build/jadupc-canonical-source` — URL/suite/comps
    parsed from the canonical line (loud refusal on exotic shapes);
    standalone equivalence test byte-identical to old literals.
    bash -n, shellcheck, dry-run, hardcoded-names checker clean.
- [x] **B5. Security pocket (S6, needs Q2)** — S–M
  - Status: [x] done, merged (PR #71) — Q2 decided in:
    `trixie-security` unconditional, same signed-by. Merge-push build
    assembled the new source with no mmdebstrap errors (pocket fetch
    proven); handoff quota-blocked as usual, publish skipped.
    NOTE for #68: rows from this push onward carry security-pocket
    versions — discontinuity logged.
- [x] **B6. Labels (S7/S8, verify `URL_SOURCE` first)** — S
  - Status: [x] done, merged as 9defa181 (PR #67) — URL_SOURCE verified
    present via brand-loaded urls.env; source/url/vendor split, bare
    version, codename vendor label. Noted: URL_SOURCE aims at the JaduPC
    org while the repo lives at fa-saikat — var used as-is, URL fix separate.
- [x] **B7. `rmi` on failure (S9)** — S
  - Status: [x] done, merged as 9defa181 (PR #67) — guarded for set -u,
    proven by green --dry-run (trap ran with IMAGE_REF unset).
- [ ] **E1+E2. Release promotion runbook + GHCR visibility (D4/D6)** — M+S
- [x] **F3. Grype graduation rule (W13)** — S + tracking issue
  - Status: [x] done, merged (PR #69) — rule in-workflow (10-push
baseline, fail on Critical-with-fix), issue #68 with seed + logbook.
Row 1 (dev push 36472466697): SBOM 648, total 1979, Critical 43
(2 with fix), High 422 (25 with fix). Real-schema jq proven.
CORRECTION: no SBOM shift from ca-certificates (still 648) — it was
already pulled in as a dependency; the explicit include is
belt-and-braces, baseline unmoved.
- [x] **G2. Self-hosted fork-PR warning (D7)** — done: constraint noted
  in `container-build.yml` header + `ci-cd.md` self-hosted bullet.
- [ ] **G1/G3/G4. Remaining extras (W12/W13/metrics)** — as time allows

## Definition of done (from audit §5)

A1 PR-only path change triggers build; rapid pushes both complete; PR shows
no write perms; SBOM failure leaves GHCR empty; wrong-identity verify red;
manifest == registry digest asserted; smoke installs absent package; no creds
in env; hardcoded-names checker passes; absence test green + red on sabotage;
double-build recorded; docs match YAML.

## Open decisions blocking steps (audit §3)

Q1 DECIDED baked (repo + keyring ship in-image; keyring rotation =
image rebuild) · Q2 security pocket (blocks B5) ·
Q3 Tier B (blocks C1) · Q4 sign/attest run on real push? (run UI) ·
Q5 `:DISTRO_VERSION`/`stable` promotion local (blocks E1).
