# ADR-007: ISO-Only Distribution — No Phase-3 APT Repository Work

**Status:** Accepted
**Date:** 2026-09-23

## Context

The DevOps plan's Phase 3 proposed standing up APT repository infrastructure (`aptly` with snapshot-based promotion) as the artifact-management equivalent. But that presupposed an unanswered question: does ShopnoOS distribute individual `.deb`s to users (people running `apt update` against a ShopnoOS repo), or is it ISO-only? Building repository infrastructure before answering that is portfolio-scope busywork. Deciding late also costs little — Phase 3 is cleanly additive either way.

## Decision

ISO-only. No `aptly`, no snapshots, no repo server to operate, no Phase-3 workstream at all. Users get ISOs; `publish.sh` rsyncing whole artifacts to the mirror stays the distribution mechanism. This changes nothing about *build-time* package sources: `deb.jadupc.com` remains where `shopno-os-*` and similar packages are fetched from during builds — it is a source, not a project, and operating no infrastructure means there is nothing to promote, snapshot, or reconcile. `secrets/repo-signing.env` stays dormant.

## Consequences

- An entire phase (repo server, snapshot promotion, repo-signing operations) is deleted from the roadmap, freeing the schedule for supply-chain work (Phase 4) with a better hiring-signal-to-effort ratio under a tight timeline.
- If per-package distribution is ever wanted, the recorded starting point is `aptly` scoped to internal `shopno-os-*` packages only — never a Debian mirror.
- Reopening requires evidence, not enthusiasm: real users needing `apt update` against a ShopnoOS repo, or a support burden traceable to ISO-only distribution.
