# ADR-009: Container Content Gate — Ceiling and Absence Where ISOs Use Floor

**Status:** Accepted
**Date:** 2026-09-29

## Context

ADR-003 settled the ISO package gate as floor plus critical-list: the
regression that matters for ISOs is catastrophic package *loss*, so the
test trips on drops, not growth. The container image has the opposite
risk profile. Its denylist (`container-exclude.txt`) is subtractive:
new base packages flow into the image by default, so the failure mode
is silent *growth* — a daemon or hardware tool landing in a minimal
base nobody asked for. A floor-only gate would bless that growth.

## Decision

- **Absence gate:** `tests/smoke/test-container-packages.sh` fails the
  build if any installed package matches a denylist pattern, checked
  against the built artifact via `dpkg-query` (same artifact-derived
  truth discipline as ADR-003), cross-checked against the SBOM.
- **Ceiling plus floor:** the fixture
  (`tests/fixtures/expected-container-packages.json`) carries
  `[total_min, total_max]` per profile. Either bound trips.
- **Critical list, shared shape:** same `critical_packages` idea as the
  ISO fixture, same `validated_against_real_image` flag discipline —
  provisional wide band until real image builds land, then tighten.
- **Blocking step** in `container-build.yml`, placed before the publish
  handoff: a gate failure must never reach the registry.

## Consequences

- Layer edits that pull Tier-B-shaped packages into the image now fail
  loudly at PR time instead of shipping silently.
- Count bands need re-baselining on deliberate composition changes
  (Tier-B rulings, security-pocket-class shifts) — recorded in the
  fixture and the grype logbook, never bumped blindly.
- Reopening (e.g., allow-list instead of denylist if exclusions approach
  half the source list, per the Q3 recommendation) needs a new ADR, not
  gate edits.
