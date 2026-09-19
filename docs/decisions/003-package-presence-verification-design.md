# ADR-003: Artifact-Derived, Rootless Package-Presence Verification with Floor + Critical-List Strictness

**Status:** Accepted
**Date:** 2026-09-19

## Context

`tests/smoke/test-packages-present.sh` needed to answer whether a built ISO actually contains what its layers declared — a question `lint-packages.sh` cannot answer, since lint only checks source `.list.chroot` files, never a
built artifact. Four design questions had to be settled together: where the ground truth comes from, whether root is acceptable, how many profiles need real baselines before Phase 2 counts as proven, and how strict the pass/fail
check should be.

## Decision

- **Artifact-derived, not source-derived.** Truth comes from `var/lib/dpkg/status` inside the built squashfs, extracted from the actual ISO — not from re-summing package lists, which would only re-test lint's
  own input and catch nothing lint doesn't already catch.
- **Rootless by construction.** ISO extraction (xorriso, with a 7z fallback for >4GB squashfs images xorriso 1.5.x cannot parse) and a single-file `unsquashfs` of the dpkg status database — never a loop mount — so the test runs in unprivileged CI without a sudo dependency.
- **All three profiles get real baselines**, not just the ones that are convenient to build. `core` is explicitly tracked as an open gap (issue filed) rather than silently left on a source-derived floor.
- **Floor + critical-package list, not exact counts.** An exact count goes stale on every upstream Debian dependency change and trains people to bump numbers blindly without looking. A floor catches catastrophic drops; the critical list catches layer-merge regressions deterministically.

## Consequences

- `expected-package-counts.json` carries a per-profile `validated_against_real_iso` flag rather than one global bool, so a source-derived-only floor (unvalidated) is visibly weaker than one recalibrated from a real build, and the two are never conflated.
- The 7z fallback is now load-bearing for at least `gaming-xfce`, whose squashfs already exceeds xorriso 1.5.x's multi-extent limit — this is a real, not hypothetical, dependency.
- The floor is deliberately loose (real observed counts of 1812/1852 vs. floors of 1500) — the test is a regression tripwire against catastrophic package loss, not a precise accounting tool.
