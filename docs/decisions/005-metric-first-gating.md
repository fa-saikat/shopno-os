# ADR-005: Metric-First Gating with Evidence-Based Graduation

**Status:** Accepted
**Date:** 2026-09-22

## Context

A gate that fails for environmental reasons trains the team to override gates, after which gates are decoration. Twice now a check was proven locally but unproven in CI: the boot gate under hosted TCG emulation (no `/dev/kvm`), and desktop boot timeouts (600s red, 1800s green — same artifact). Blocking PRs on either immediately would have vetoed good changes for runner slowness.

## Decision

New gates ship `continue-on-error: true` (metric, not gate) with the promotion rule written down at introduction: what evidence graduates it (N consecutive greens, or a runner capability landing), tracked in a dedicated issue with run URLs as the logbook. Per-profile timeouts follow the same rule — core keeps 600s (measured), desktop gets the measured 1800s bound, and the step's full-timeout consumption is documented rather than wished away. This formalizes the precedent already set with non-blocking `grype` scanning.

## Consequences

- An always-orange metric is treated as a bug in the metric (retune the bound, as with 600→1800s), never as background noise to ignore.
- Graduation removes one line; the evidence log in the tracking issue is what justifies it, not elapsed time or optimism.
- Cost is explicit: metric legs still consume runner minutes while proving themselves — early-exit polling is the tracked answer to that cost, not premature graduation.
