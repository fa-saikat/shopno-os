# ADR-006: Releases Stay Local — No Signing Keys in CI, No Tag-Triggered Rebuilds

**Status:** Accepted
**Date:** 2026-09-23

## Context

A tag-triggered `release.yml` (build all profiles, sign, publish on `git tag v*`) is the conventional shape, and both `architecture.md` §13 and `release-process.md` §1 once described it as the plan. Three facts argue against it here: the private release key lives on the maintainer's machine and CI has no legitimate need for it; `build-iso.yml` already gates every PR on `dev`, so a post-tag rebuild would re-prove nothing; and `publish.sh` rsyncs from a local staging directory CI never possesses.

## Decision

Releases run locally, by hand, per `docs/release-process.md`: changelog, version bump, build all profiles, verify, sign with the local key, fast-forward `main`, tag, `publish.sh`, then a one-line `gh release create`. No private key material ever enters GitHub secrets. No workflow rebuilds, signs, or publishes on tag push — a tag-triggered `release.yml` is declined, not deferred. CI's role ends at proof: lint plus build-and-gate on PRs to `dev`.

## Consequences

- A rebuild can never silently substitute different bits for verified ones — promotion (merge the proven state) is the only path to `main`, and the tag marks it rather than triggering work.
- The one CI-shaped gap this leaves is third-party verification of shipped bits (an independent party checking the mirror's checksums/signatures). If ever wanted, that is a *verifier* workflow — it reads published artifacts, never builds or signs — and needs its own proposal, not a revival of this one.
- Reopening this decision requires a concrete need CI alone can serve (e.g., multiple releasers without shared machine access), not a general preference for automation.

## Amended 2026-09-23 — Narrowing the Principle

The container workflow (ADR-008) pushes images to a registry from CI, which contradicts this ADR's literal sentence ("CI's role ends at proof... never publishes") while honoring its actual reasoning. The stated principle is therefore narrowed from "CI never publishes" to what it was protecting all along:

> **CI never holds long-lived, high-blast-radius credentials.**

Keyless `cosign` signing via per-run GitHub OIDC and GHCR pushes via the ephemeral, per-run `GITHUB_TOKEN` (`packages: write`) leave nothing that persists past the run — no static credential exists to leak, rotate, or steal. That is the same thesis as the Phase 5 GitOps boundary ("CI never holds cluster credentials"), now applied twice. Everything else in this ADR stands unchanged: ISO releases stay local, the private GPG key stays home, and no tag-triggered rebuild exists.
