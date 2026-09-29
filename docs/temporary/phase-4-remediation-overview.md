# ShopnoOS Phase 4 Remediation — Session Overview

**What this is:** a plain-language record of everything done in the Phase 4 remediation session (late September 2026), written for newcomers. It covers what was broken, what we changed, how the pipeline works today, how to do everyday tasks step by step, what still needs follow-up, and which chores recur forever.

**How to read it:** start at §1 for the story, jump to §5 if you only want the diagrams, §6 if you want hands-on directions. Companion files: `phase-4-implementation-limitation.md` (the original audit register — read that for the *why* behind every item) and `phase-4-remediation-steps.md` (the checkbox tracker with per-item evidence).

---

## 1. TL;DR

Phase 4 built a working container pipeline (build → smoke → SBOM → scan → push → sign → attest). A post-Phase-4 review found it published before proving, skipped builds on package changes, leaked credentials, and overclaimed in docs. This session fixed all of that across 14 merged PRs, added two executable gates (signature verification, content audit), one metric with a graduation plan (grype), a measured determinism result (MATCH), and a release promotion runbook. Three proofs still wait on GitHub artifact-quota recovery; everything else is merged and green.

---

## 2. Starting Point

`dev` HEAD sat at the merged Phase 4 slices (script, workflow, SBOM/scan, sign/attest) with a fresh, uncommitted audit file. The audit graded ~30 limitations (workflow trust, script hygiene, design gates, doc drift) and proposed a sequenced remediation plan. Standing context that shaped every decision: `dev` authoritative with PR gating, `main` fast-forward plus tags only, ISO releases stay local with no CI-held signing keys (ADR-006 narrowed to "no long-lived high-blast-radius credentials"), digest-not-tag verification, metric-first graduation (ADR-005), and a recurring GitHub artifact-storage quota that makes uploads fail several times a week (uploads are `continue-on-error` by design, so quota can never veto a verdict).

---

## 3. What We Did, Slice by Slice

**A1 — Path-filter coverage (PR #61, fix #62 proof).** The container workflow only ran when its own script, denylist, or workflow file changed, so package-list, profile, keyring, library, and brand edits silently skipped it while `:edge` went stale. Added six path groups to both PR and push filters. Proved with scratch PR #62 (touched only a package list, watched the container leg fire, closed unmerged). Standing rule adopted: any file the workflow consumes belongs in the filter (this caught a repeat later when the new gate files were missing from it).

**Trust unit — Prove before publish (PR #63, issue #64 pending).** The headline fix. One job used to push to GHCR *before* SBOM/scan/sign ran (a late failure stranded a public unsigned image), held workflow-wide write/OIDC rights while running `sudo` on repo code, allowed newer pushes to cancel older ones mid-sign, re-read digests from the mutable `:edge` tag, and never verified its own signatures. Now: a least-privilege `build` job (contents-read only) proves tarball/smoke/SBOM/scan and uploads a blocking handoff; a push-gated `publish` job pushes via `--digestfile`, signs keyless, attests provenance plus SBOM, then verifies both (blocking). Cancellation is PR-only. First full push-half proof waits on quota recovery (issue #64); the design fails closed until then (red run, nothing published).

**Script hygiene + small cleanups (PR #65).** Removed credential loading from a script that never used secrets (live creds were reaching child processes), pinned `SOURCE_DATE_EPOCH` before all derivations, pinned the image timestamp (`--timestamp`, flag verified on local buildah 1.39.3 and the CI runner), derived the image name from the repo instead of hardcoding, and wired the dead dispatch input through with a safe default.

**Docs + ADR-008 (direct to dev).** Rewrote the drifted pipeline docs to the as-built two-job reality (sudo correction, slice 4 marked live with #64 pending, attest-sbom, provenance limits, retention truth), fixed the architecture tree (dropped the declined `release.yml`, added the missing `container-build.yml`), scoped "reproducible" down to "input-pinned, unmeasured," and appended an ADR-008 amendment in ADR-006's style.

**Q1 + smoke honesty (PR #66).** Two discoveries in one slice. First the test: it installed `curl`, which already ships in the image, so the install half proved nothing, and the comment claimed the project repo worked inside an artifact that never contained it. Fixed to install-and-run `hello` (index-verified present in trixie, guaranteed absent from minbase) with the artifact's apt sources logged. Then the honest question the test exposed: should the image carry the ShopnoOS repo at all? Decided baked, not sealed. Baking it exposed the deeper bug below.

**The 99mmdebstrap find (same PR, round 2).** The new `hello` install failed with an empty package cache. Root cause, confirmed in the manpage: `mmdebstrap --aptopt` values persist permanently into the image's `/etc/apt/apt.conf.d/99mmdebstrap`, including our build-time `Dir::Etc::sourcelist` (a `/tmp` path that doesn't exist in-image) and `sourceparts "-"`. In-image apt was reading *no* sources; the old curl test had been passing vacuously for the same reason. Fix: scrub the file post-build, ship explicit `ca-certificates` (the baked repo redirects to https). Lesson recorded: a test that cannot fail proves nothing.

**Digest assert + labels + cleanup (PR #67).** Post-verify blocking assert comparing manifest digest to pushed digest (mismatch means document dual digests, never withhold signing — verdict rides the first green push). Labels corrected (`source` is the repo URL, bare version, codename to vendor namespace; URL-Source org mismatch noted, not freelanced). Interrupted builds now clean their local image-store entry.

**Grype graduation (PR #69, issue #68).** The metric had no promotion rule, violating ADR-005. Added JSON output feeding per-severity/with-fix summary counts, wrote the rule in the workflow (baseline 10 dev-push runs, then fail on 1+ Critical with fix), and opened the logbook issue. Baseline journey so far: 1979 → 1929 (security pocket cleared fixables) → 1856 (Tier-B deny) → 1817 (upstream drift), Critical-with-fix 2 → 0, six rows logged with two documented discontinuities.

**Single-sourcing the repo (PR #70).** The project repo URL/suite lived in both `jadupc.list` and the script. Now parsed from the canonical one-line file with loud refusal on exotic shapes; equivalence-tested byte-identical.

**Security pocket (PR #71).** The image had no security-updates source (the script never read the profile flag). Added `trixie-security` unconditionally with the same signed-by. Textbook effect on the next run: fixable CVEs cleared to zero.

**Content gate (PR #72, ADR-009).** Q3 Tier-B decision (deny daemons and privileged-hardware tooling by rule; 10 packages verified shipping) → denylist group → dry-run 186/67/120. New blocking gate pre-handoff: denylist absence plus critical set plus count band, artifact-derived with SBOM cross-check, provisional fixture band. Sabotage-proven on scratch PR #73 (added `curl` pattern, gate failed naming it, closed unmerged); the first attempt at that experiment (deleting entries) correctly stayed green and taught us the gate audits the list, not the unknown. Fixture tightened to observed builds (PR #74).

**Determinism measured (PR #76, script + local run).** New `scripts/dev/check-container-determinism.sh` harness; back-to-back local builds returned identical digests (`969e1d17…`), so the guide now claims "reproducible given a frozen package set" with cross-day equality explicitly unclaimed.

**Release promotion (direct to dev).** `release-process.md` §8.3: verify-then-retag to `:DISTRO_VERSION`/`:stable` locally with short-lived auth, never rebuild (signatures follow digests), plus the one-time GHCR visibility flip. Old §§8.3–8.4 renumbered.

**Extras (PRs #77, #78; G2 direct).** Tarball size in the run summary (first datapoint 463M), all 11 action refs pinned to verified commit SHAs (attest tags peeled from annotated tag objects) with weekly Dependabot, self-hosted fork-PR warning. G3 (SARIF to code scanning) deferred with reason: private repo without GHAS would fail the upload.

---

## 4. Commit and PR Record

Merged to `dev` this session: #61 (path filters), #63 (trust unit), #65 (hygiene), #66 (baked repo + honest smoke), #67 (assert/labels/cleanup), #69 (grype rule), #70 (single-sourcing), #71 (security pocket), #72 (content gate), #74 (fixture tightening), #76 (determinism harness), #77 (size metric), #78 (SHA pinning). Closed unmerged as proofs: #62 (trigger), #73 (sabotage), #75 (superseded harness attempt). Open tracking issues created: #64 (publish proof), #68 (grype logbook). Commit style throughout: layer prefixes (`build:`/`ci:`/`tests:`/`docs:`/`fix:`), lowercase imperative subjects under 72 chars, bodies wrapped at 80 only in commits (never in docs or PR text).

---

## 5. How the Pipeline Works Today

Three workflows, three jobs each with one responsibility:

```
push to any branch ──▶ Lint (skips docs-only changes)
PR to dev ──▶ Lint + ISO matrix [core, desktop-xfce] + Container build job
merge to dev ──▶ Lint + Container build job ──▶ (handoff) ──▶ Container publish job
dispatch ──▶ one ISO profile, or one container profile (no publish, no lint)
main ──▶ Lint only (nothing rebuilds; tags mark proven state)
```

Container `build` job (least privilege, contents-read only):

```
checkout → install deps → build tarball (sudo) → locate → smoke (hello)
  → install syft/grype → SBOM (blocking) → scan (metric) → content gate (blocking)
  → handoff upload [push only, blocking] → evidence upload [always, non-blocking]
```

Container `publish` job (push only, holds the only write/OIDC rights):

```
download handoff → push SHA tag (digest from push) → copy digest to :edge
  → sign → attest provenance + SBOM → verify both → assert manifest==registry
```

Design rules that must survive future edits: proof precedes publication (nothing pushes before SBOM/scan/gate pass); least privilege (build can never publish even on misconfiguration); digest-not-tag everywhere past the push; uploads never veto verdicts except the handoff, which fails closed by deleting nothing and publishing nothing; any file the workflow consumes belongs in its path filter.

---

## 6. Containerization in One Page

`scripts/build/build-container.sh` resolves the base+core package lists, subtracts `container-exclude.txt` (projection, not a second source of truth — the Golden Rule holds), assembles explicit APT sources (Debian suite + updates + security with host keyring, project repo with its own dearmored key), builds a minbase rootfs with `mmdebstrap` under sudo, scrubs the build-time apt config leak, bakes the project repo + keyring into the image (Q1), pins timestamps, assembles via `buildah bud` from a generated `FROM scratch` Containerfile, and exports tarball + manifest with `--digestfile` capture. Labels carry brand identity (source/url/vendor split, bare version). The image is measured reproducible given a frozen package set (D-1 MATCH); cross-day equality is unclaimed because mirrors move.

---

## 7. Step-by-Step Directions

**Everyday change (feature/fix):**
1. `git checkout dev && git pull --ff-only`, then `git checkout -b <prefix>/<name>` (`ci:`, `build:`, `tests:` by area).
2. Edit, then validate locally: `bash -n` + `shellcheck` for scripts, `--dry-run` for the container script, `actionlint` + YAML parse for workflows, the matching lint checker for the area.
3. Stage explicit paths only (never `-A`), commit per area with a lowercase prefixed subject, push, open a PR to `dev` with Summary/Testing/Risk sections.
4. Watch the legs that concern your change; cancel unrelated ISO legs if they fire (container-only edits trigger them via the shared `scripts/build/**` filter — noise, not signal).
5. Merge on green, `git checkout dev && git pull --ff-only`, delete the branch both ends (`-d` verifies merged status; `-D` only for closed-unmerged scratch branches).

**Proving a trigger or a gate (scratch pattern):** branch off `dev`, make the minimal touching change (one comment line for triggers; one added pattern for the gate), open a `DO NOT MERGE` PR, read the verdict (fired/stayed-green or red as designed), close unmerged, delete the branch. Used for #62 (trigger), #73 (gate teeth).

**Re-running after quota:** `gh run rerun <run-id>` preserves the push event, so the publish job executes. Only reruns prove publish-side changes; PR runs never can.

**Logging a #68 row:** copy SBOM count, findings total, severity line, and tarball size from a completed dev-push summary into the next table row with date, run URL, and a note (name discontinuities: pocket, Tier-B, band changes). Ten rows with an agreed threshold graduate the gate by removing one line.

**Release promotion (§8.3):** only after a fully green dev push exists. Copy its digest from the run summary, `cosign verify` it, `skopeo login` with an ephemeral `gh` token, `skopeo copy` the digest to `:DISTRO_VERSION` and `:stable`. Never rebuild. First release also flips GHCR package visibility to public in the UI.

**Re-measuring determinism:** `./scripts/dev/check-container-determinism.sh` on a sudo machine (add root's `safe.directory` exception first or git refuses under sudo). MATCH closes the question again; DIFFER goes to `diffoscope-minimal` (not the 2GB full package) and gets recorded.

---

## 8. Follow-ups Still Open

Quota-gated (re-run when storage recovers): #64 (first green push → sign/attest/verify + A6 digest answer in one run), A7 negative test (wrong-identity verify must go red). Release-gated: first live §8.3 promotion + E2 visibility flip. Deferred with reason: G3 (needs public repo or GHAS). Never scheduled (declined, not deferred): `release.yml`, tag rebuilds, desktop container variants, allow-list conversion (needs its own ADR if exclusions ever approach half the list).

---

## 9. Recurring Processes (the forever list)

- **#68 logbook to 10 rows, then graduate.** Every dev push appends a row; name every discontinuity; at row 10 with an agreed threshold, remove `continue-on-error` and verify the first deliberate red.
- **Dependabot PRs, weekly.** Review and merge action-pin updates deliberately; glance at the Dependabot tab after any silence.
- **Quota awareness.** Exhaustion recurs every few days (6–12h recalc). Upload failures are environmental: evidence uploads absorb them, the handoff fails closed. Never "fix" a quota red by weakening a gate; re-run instead.
- **Fixture re-baselining on deliberate composition changes.** Tier rulings, pocket-class shifts, and suite changes move counts by design — update the fixture band and log the discontinuity in the same PR, never bump numbers blindly.
- **Docs-match-YAML discipline.** Every workflow change updates `ci-cd.md` §2.3/§3, the guide, or the ADR in the same PR. The drift that motivated F1 returns within weeks without this.
- **Determinism re-runs** on buildah moves, new rootfs-mutating steps, or suite changes; **safe.directory** setup on every new sudo build machine.

---

## 10. Where Things Go From Here

The remediation is complete to the extent action allows: code, tests, docs, and measurements are merged; only quota, a release event, and the graduation count stand between now and "Phase 4 rock solid" (at which point this temporary directory is deleted per its own header). The natural next chapters are owned elsewhere: boot-gate graduation (#42) and self-hosted runners (#46) in the ISO world, the grype graduation flip from the logbook you are already filling, and the first real release exercising §8.3 end to end. None of them need new architecture — just the scheduled events, faithfully logged.
