#!/usr/bin/env bash
# =============================================================================
# tests/smoke/test-container-image.sh
# ShopnoOS - Container Image Smoke + SBOM + Scan (local equivalent of the
# container-build.yml middle steps: load, exercise, SBOM, scan, summarize)
#
# USAGE:
#   ./tests/smoke/test-container-image.sh <path/to/*.oci.tar> [options]
#   sudo ./tests/smoke/test-container-image.sh build/container/*.oci.tar
#
# WHAT IT DOES (mirrors CI step for step):
#   1. Loads the tarball into a runtime (docker daemon if alive, else
#      buildah working storage - same assertion either way, see below).
#   2. Prints the image's own APT sources (proves what the artifact, not
#      the build log, actually contains).
#   3. Installs-and-runs `hello` (index-verified present in trixie,
#      guaranteed absent from minbase): proves repo reachability AND
#      installability. Installing an already-present package proves
#      nothing - see container-guide.md.
#   4. Generates SPDX SBOM next to the tarball (blocking - no SBOM means
#      nothing downstream has input).
#   5. Runs grype scan to table + SARIF (metric only - base images always
#      carry CVEs; gating waits on a trusted baseline per ADR-005).
#   6. Prints the run summary block (same lines CI appends to the step
#      summary): packages, findings, digest.
#
# OPTIONS:
#   --workdir D     Scratch dir for logs (default: mktemp, removed on exit)
#   --keep-workdir  Keep scratch dir for inspection
#   --skip-scan     Skip the grype step (SBOM still generated)
#   -h, --help      Show this help
#
# EXIT CODES:
#   0 - smoke passed (scan findings never fail this script - metric only)
#   1 - load/smoke/SBOM failure, or missing commands/tarball
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../scripts/lib"

# shellcheck source=../../scripts/lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <path/to/image.oci.tar> [options]

Options:
  --workdir D     Scratch dir (default: mktemp, removed on exit)
  --keep-workdir  Keep scratch dir for inspection
  --skip-scan     Skip grype (SBOM still generated)
  -h, --help      Show this help

Needs (sudo where the tarball is root-owned): skopeo or buildah,
docker daemon OR working buildah storage, syft, grype (unless
--skip-scan), jq.
EOF
    exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && _usage
[[ $# -eq 0 ]] && _usage

TARBALL_PATH="${1:-}"
OPT_WORKDIR=""
OPT_KEEP_WORKDIR=0
OPT_SKIP_SCAN=0
shift || true

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --workdir)      OPT_WORKDIR="${2}"; OPT_KEEP_WORKDIR=1; shift ;;
        --keep-workdir) OPT_KEEP_WORKDIR=1 ;;
        --skip-scan)    OPT_SKIP_SCAN=1 ;;
        -h|--help)      _usage ;;
        *) log_error "Unknown option: ${1}"; _usage ;;
    esac
    shift
done

require_file "${TARBALL_PATH}"
require_command skopeo jq syft
[[ "${OPT_SKIP_SCAN}" -eq 0 ]] && require_command grype

TARBALL_DIR="$(cd "$(dirname "${TARBALL_PATH}")" && pwd)"
SBOM_OUT="${TARBALL_DIR}/sbom.spdx.json"
SARIF_OUT="${TARBALL_DIR}/grype.sarif"

if [[ -n "${OPT_WORKDIR}" ]]; then
    WORKDIR="${OPT_WORKDIR}"
    mkdir -p "${WORKDIR}"
else
    WORKDIR="$(mktemp -d /tmp/shopno-os-container-smoke.XXXXXX)"
fi
if [[ "${OPT_KEEP_WORKDIR}" -eq 0 ]]; then
    trap 'rm -rf "${WORKDIR}"' EXIT
else
    trap 'log_info "Workdir kept at: ${WORKDIR}"' EXIT
fi

# ---------------------------------------------------------------------------
# Step 1: pick a runtime (docker daemon if alive, else buildah storage)
# ---------------------------------------------------------------------------
RUNTIME=""
REF=""
CTR_ID=""
if docker info > /dev/null 2>&1; then
    RUNTIME="docker"
    REF="smoke-test:local"
    log_step "Loading image via docker daemon"
    _run skopeo copy "oci-archive:${TARBALL_PATH}" "docker-daemon:${REF}"
elif command -v buildah > /dev/null 2>&1; then
    RUNTIME="buildah"
    log_step "Docker daemon unreachable - working via buildah storage"
    # One working container for the whole run (created once, removed in
    # cleanup). No tags involved - raw container ID throughout.
    CTR_ID="$(buildah from "oci-archive:${TARBALL_PATH}")"
    [[ -n "${CTR_ID}" ]] \
        || { log_error "buildah from produced no container ID."; exit 1; }
    log_info "Working container: ${CTR_ID}"
else
    log_error "Neither a live docker daemon nor buildah is available."
    exit 1
fi

_run_container() {
    # "$@" stays quoted: unquoted it re-splits AND re-globs the inner
    # script on the HOST (proven: host /etc/apt/sources.list.d/*.sources
    # leaked into the command, and bare `cat` hung on stdin forever).
    # The `--` separator is required back: it was dropped suspecting
    # buildah rejected it ("exec: no command"), but bare-metal testing
    # proved the real cause was a missing crun binary - `--` works fine
    # and protects against leading-dash arguments. Do not remove again
    # without re-running that experiment.
    if [[ "${RUNTIME}" == "docker" ]]; then
        docker run --rm "${REF}" "$@" < /dev/null
    else
        buildah run "${CTR_ID}" -- "$@" < /dev/null
    fi
}

_cleanup_runtime() {
    if [[ "${RUNTIME}" == "docker" ]]; then
        docker rmi "${REF}" > /dev/null 2>&1 || true
    elif [[ -n "${CTR_ID}" ]]; then
        buildah rm "${CTR_ID}" > /dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Step 2: show the image's own APT sources (artifact truth, not build log)
# ---------------------------------------------------------------------------
log_step "Image APT sources (as shipped)"
_run_container bash -c 'cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; echo ---; cat /etc/apt/apt.conf.d/* 2>/dev/null' || true

# ---------------------------------------------------------------------------
# Step 3: install-and-run hello (proves repo + installability, not presence)
# ---------------------------------------------------------------------------
log_step "Smoke: install and run hello"
_run_container bash -c 'apt-get update && apt-get install -y --no-install-recommends hello && hello'

# ---------------------------------------------------------------------------
# Step 4: SBOM (blocking - everything downstream needs it)
# ---------------------------------------------------------------------------
log_step "Generating SBOM"
_run syft scan "oci-archive:${TARBALL_PATH}" -o "spdx-json=${SBOM_OUT}"
SBOM_COUNT="$(jq '.packages | length' "${SBOM_OUT}")"
log_info "SBOM packages: ${SBOM_COUNT}"

# ---------------------------------------------------------------------------
# Step 5: grype scan (metric only - never gates this script)
# ---------------------------------------------------------------------------
FINDINGS="skipped"
if [[ "${OPT_SKIP_SCAN}" -eq 0 ]]; then
    log_step "Vulnerability scan (metric only)"
    grype "sbom:${SBOM_OUT}" -o table || true
    grype "sbom:${SBOM_OUT}" -o "sarif=${SARIF_OUT}"
    FINDINGS="$(jq '[.runs[].results // empty | .[]] | length' "${SARIF_OUT}")"
    log_info "Grype findings: ${FINDINGS} (metric only - see ${SARIF_OUT})"
fi

# ---------------------------------------------------------------------------
# Step 6: run summary (same lines CI appends to the step summary)
# ---------------------------------------------------------------------------
DIGEST="$(jq -r '.output.digest // empty' "${TARBALL_DIR}/container-manifest.json" 2>/dev/null || true)"
log_step "Run summary"
log_info "- SBOM packages: ${SBOM_COUNT}"
log_info "- Grype findings: ${FINDINGS} (metric, non-blocking)"
[[ -n "${DIGEST}" ]] && log_info "- Manifest digest: ${DIGEST}"

_cleanup_runtime
trap - EXIT
[[ "${OPT_KEEP_WORKDIR}" -eq 0 ]] && rm -rf "${WORKDIR}"
log_success "Container smoke test PASSED: $(basename "${TARBALL_PATH}")"
exit 0
