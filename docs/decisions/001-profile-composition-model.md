# ADR-001: Profile-Based Composition Engine over Flat `auto/config`

**Status:** Accepted
**Date:** 2026-09-18

## Context

A generic DevOps reference architecture for `live-build`-based distros proposes a single flat `auto/config` script holding all `lb config` flags, versioned as one file. ShopnoOS instead composes each ISO from four independent layers (`base/` → `editions/<n>/` → `flavors/<n>/` → `hardware/<n>/`), declared per-profile in `profiles/<name>/profile.env` + `profiles/<name>/lb_config.sh`, and assembled at build time by `prepare-lb-config.sh` and `inject-packages.sh`.

The question: adopt the simpler flat scaffold for CI/DevOps work, or keep the existing composition engine and build DevOps tooling around it.

## Decision

Keep the existing profile composition engine. It is not "a `live-build` config with extra steps" — it already solves a problem the flat scaffold doesn't address at all: producing an edition × flavor × hardware matrix (currently 6+ profiles) from shared layers with zero duplication, enforced by `lint-packages.sh`'s cross-layer duplicate check. A flat `auto/config` has no notion of layers, so the same coverage would require one config file per profile with copy-pasted package lists — reintroducing the exact duplication the Golden Rule ("a package lives in exactly one place") exists to prevent.

DevOps additions (CI matrix, boot gate, caching) wrap `build.sh` and read from `profiles/`; they do not replace or flatten it.

## Consequences

- CI cache keys can hash per-layer package lists instead of the whole tree, since layers are already file-system-isolated — finer-grained invalidation than a flat scaffold would allow.
- Onboarding cost is higher: a new contributor must understand four layers and the merge order before touching a build, versus one flat file.
- Adding a new edition/flavor/hardware combination is a profile addition, not a new build script — this is the trade-off paying off as the matrix grows.
