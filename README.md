# ShopnoOS

[![Lint](https://github.com/fa-saikat/shopno-os/actions/workflows/lint-packages.yml/badge.svg)](https://github.com/fa-saikat/shopno-os/actions/workflows/lint-packages.yml)
[![Build ISO](https://github.com/fa-saikat/shopno-os/actions/workflows/build-iso.yml/badge.svg)](https://github.com/fa-saikat/shopno-os/actions/workflows/build-iso.yml)
[![Build Container](https://github.com/fa-saikat/shopno-os/actions/workflows/container-build.yml/badge.svg)](https://github.com/fa-saikat/shopno-os/actions/workflows/container-build.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A Debian-based Linux distribution built from composable layers — with a build, test, and supply-chain pipeline that proves every artifact instead of just producing it.

> ShopnoOS 2.2 "Uday" · Debian trixie base · `dev` is where work lands, `main` takes merges + tags only.

---

## What makes it different

Most small distros are a pile of scripts around `live-build`. ShopnoOS is two projects in one:

- **The distro (the workload):** a from-scratch layered composition system — `base` + `editions` + `flavors` + `hardware`, composed per-profile at build time. A package or config file lives in exactly one place; profiles declare combinations, never copies.
- **The pipeline (the project):** everything around the distro is gated and evidenced — lint on every push, ISO matrix builds with boot + package smoke gates on every PR, OCI images with SBOM, vulnerability scans, keyless signing, and SLSA provenance. Green means proven: floors are calibrated from real builds, gates graduate on measured evidence, and honest negative results (like the published reproducibility work) count as artifacts too.

## Profiles

| Profile | Edition | Experience | Use case |
|---|---|---|---|
| `shopno-os-core` | core | TTY only | Servers, containers seeds, netboot |
| `shopno-os-desktop-xfce` | desktop | XFCE | General-purpose desktop |
| `shopno-os-gaming-xfce` | gaming | XFCE | Gaming + media (RetroPie, Kodi) |

## Quickstart

```bash
# Build an ISO (needs Debian host, root, live-build toolchain)
sudo ./scripts/build/build.sh shopno-os-core
# → build/output/shopno-os-2.2-core-none-<arch>-<date>.iso

# Build the OCI image instead (minutes, rootless where possible)
./scripts/build/build-container.sh
# → build/container/*.oci.tar + container-manifest.json

# Or pull the prebuilt image - no build needed
docker pull ghcr.io/fa-saikat/shopno-os:edge
docker run --rm -it ghcr.io/fa-saikat/shopno-os:edge bash
```

Verify what you got (same checks CI runs):

```bash
./tests/smoke/test-iso-boots.sh build/output/<iso>          # UEFI boot gate
./tests/smoke/test-packages-present.sh build/output/<iso>   # artifact contents gate
./tests/smoke/test-container-image.sh build/container/*.oci.tar  # image + SBOM + scan
```

## Repository layout

```
base/          shared by every ISO (kernel, systemd, security baseline)
editions/      what the OS does (core, desktop, gaming)
flavors/       what it looks like (xfce, minimal-x)
hardware/      optional overlay, applied last, always wins conflicts
brand/         all identity in one place (nothing else may hardcode names/URLs)
profiles/      composition declarations: edition + flavor + hardware + arch
scripts/       build / dev / lib / release tooling (lb build is never invoked directly)
tests/         lint suites + smoke gates + expected-count fixtures
infra/         self-hosted runner as Terraform + cloud-init (reproducible CI hardware)
docs/          guides, ADRs (001–009), CI/CD reference, release process
```

## Documentation

| Doc | For |
|---|---|
| `docs/build-guide.md` | Building your first ISO |
| `docs/container-guide.md` | Container image + supply chain, end to end |
| `docs/ci-cd.md` | What CI runs, on what trigger, and why |
| `docs/release-process.md` | The manual release checklist (releases stay local by design — ADR-006) |
| `docs/decisions/` | Architecture Decision Records, including amended ones |
| `docs/naming-law.md`, `docs/package-ownership.md`, `docs/branding-guide.md` | The rules that keep the layers honest |

## Contributing

All work lands on `dev` through pull requests — CI gates every one (lint always; ISO matrix and container build where paths match). Read `CONTRIBUTING.md`, then `docs/adding-edition.md` / `docs/adding-flavor.md` for layer authoring. Commit style: layer-aware prefixes (`base:`, `edition(..):`, `build:`, `ci:`, `tests:`, `docs:`, `fix:`), bodies wrapped at 80 columns.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Built on Debian trixie.
