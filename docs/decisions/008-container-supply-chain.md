# ADR-008: Container Build, Tagging, and Keyless Supply Chain

**Status:** Accepted
**Date:** 2026-09-23

## Context

Phase 4 needs a container image plus supply-chain evidence (SBOM, scan, signature, provenance), built in CI. Four design questions had to be settled first: where the workflow lives, when registry writes happen, what tags mean, and how this squares with ADR-006's "CI never publishes" — answered below, in that order.

## Decision

- **Separate workflow file** (`container-build.yml`), same isolation argument as the build script itself: disjoint triggers (`push: [dev]` exists here precisely because `build-iso.yml` deliberately lacks it), disjoint artifact lifecycles (registry-immutable tags vs 7-day ISO retention), disjoint timeout tuning. Coupling them would let one workload's calibration leak into the other.
- **Prove on PR, push on merge.** The image builds and smoke-tests on pull requests without registry writes; merge to `dev` pushes. Cheap proof pre-merge, no cleanup on close.
- **Tags are convenience pointers; verification is always digest-based.** Release builds tag `:<DISTRO_VERSION>` (same identity authority as the ISO naming law — no second versioning scheme), every push tags `:<short-sha>` plus moving `edge`/`stable` pointers. This is `publish.sh`'s `latest`-symlink pattern reapplied to OCI tags: `stable` moving under you is expected behavior, mirroring how signatures are never generated from a mutable name.
- **Keyless everything, under ADR-006 as narrowed.** `cosign` signs the digest (never the tag) via per-run GitHub OIDC; GHCR pushes use the ephemeral per-run `GITHUB_TOKEN`. No long-lived credential exists at any point, so this publishes from CI without contradicting the credential principle.

## Consequences

- SBOM (`syft`), scan (`grype`, non-blocking first per the established pattern), signature, and SLSA provenance attach to digests in later slices — this ADR is the build/publish/tagging foundation they hang off, not the whole chain.
- `core` composition only (`base` + `core` edition, subtractive package projection); desktop variants need their own proposal.
- Reopening the tagging scheme requires a consumer confused by it in practice, not a hypothetical cleaner scheme.
