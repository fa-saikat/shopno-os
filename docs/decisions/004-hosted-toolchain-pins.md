# ADR-004: Pinned Debian Toolchain .debs on Hosted Ubuntu Runners

**Status:** Accepted
**Date:** 2026-09-22

## Context

GitHub-hosted `ubuntu-24.04` runners carry no `live-build` package at all, and their `debian-archive-keyring` (2023.4) predates the trixie archive keys — so `lb config` rejects required flags and debootstrap aborts on keyring checks. Three options existed: rewrite our flags down to whatever the host provides, switch to a self-hosted Debian runner immediately, or install Debian's own packages onto the hosted runner.

## Decision

Install Debian trixie's `live-build` and `debian-archive-keyring` `.deb`s directly in the workflow's Install step, version-pinned with `sha256sum -c` verification. Both are arch-`all` with trivial dependencies (`cpio`, `debootstrap`), so `dpkg -i` is clean with no dependency surgery.

## Consequences

- An upstream version move fails the workflow loudly (checksum mismatch) instead of silently changing the toolchain — re-pin deliberately, never by accident.
- Downgrading our flags to fit the host was rejected: the project adapts the environment to its requirements, not its requirements to the environment.
- The self-hosted runner (plan §3) remains the long-term answer; this buys its schedule instead of forcing it. Switching later is one `runs-on` line.
