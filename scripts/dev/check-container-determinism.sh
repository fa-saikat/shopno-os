#!/usr/bin/env bash
# =============================================================================
# scripts/dev/check-container-determinism.sh
# ShopnoOS - Container Double-Build Determinism Check (remediation D-1)
#
# USAGE:
#   ./scripts/dev/check-container-determinism.sh [--profile NAME]
#       [--output-base DIR] [--keep]
#
# PURPOSE:
#   Bake the same cake twice and compare. Builds the container image two
#   times back-to-back (same commit, same day) into separate directories
#   and compares the recorded image digests. A MATCH means reproducible
#   given a frozen package set; a DIFFER names the two trees for
#   `diffoscope` forensics. Cross-day equality is NOT claimed (live
#   mirrors move daily by design) and is not tested here.
#
# OPTIONS:
#   --profile NAME   Core-family profile (default: shopno-os-core)
#   --output-base D  Parent dir for the two builds (default: fresh mktemp)
#   --keep           Keep both trees even on MATCH (default: keep on
#                    DIFFER only, clean up on MATCH)
#   -h, --help       Show this help
#
# EXIT CODES:
#   0 - digests match (deterministic for a frozen package set)
#   1 - digests differ, or either build failed
#
# PREREQUISITES:
#   Passworded sudo (mmdebstrap needs real privilege on most hosts),
#   mmdebstrap, buildah, jq, gpg - the same set CI installs.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PROFILE_NAME="shopno-os-core"
OPT_OUTPUT_BASE=""
OPT_KEEP=0

_usage() {
    sed -n '2,/^# ====/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile)     PROFILE_NAME="${2}"; shift 2 ;;
        --output-base) OPT_OUTPUT_BASE="${2}"; shift 2 ;;
        --keep)        OPT_KEEP=1; shift ;;
        -h|--help)     _usage 0 ;;
        -*)            log_error "Unknown option: ${1}"; _usage ;;
        *)             log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_command sudo jq
sudo -v || { log_error "Working sudo is required (mmdebstrap needs real privilege)."; exit 1; }

if [[ -z "${OPT_OUTPUT_BASE}" ]]; then
    OPT_OUTPUT_BASE="$(mktemp -d /tmp/shopno-os-determinism.XXXXXX)"
    MADE_BASE=1
else
    MADE_BASE=0
    mkdir -p "${OPT_OUTPUT_BASE}"
fi

DIR_A="${OPT_OUTPUT_BASE}/a"
DIR_B="${OPT_OUTPUT_BASE}/b"
BUILD_SCRIPT="${OS_REPO_ROOT}/scripts/build/build-container.sh"
require_file "${BUILD_SCRIPT}"

_cleanup() {
    if [[ "${RESULT:-}" == "MATCH" && "${OPT_KEEP}" -eq 0 ]]; then
        rm -rf "${DIR_A}" "${DIR_B}"
        [[ "${MADE_BASE}" -eq 1 ]] && rmdir "${OPT_OUTPUT_BASE}" 2> /dev/null || true
    else
        log_info "Trees kept at: ${DIR_A} ${DIR_B}"
    fi
}
trap '_cleanup' EXIT

# ---------------------------------------------------------------------------
# Two back-to-back builds (same commit, same day: minimal mirror drift)
# ---------------------------------------------------------------------------
RESULT=""
log_step "Build A (${PROFILE_NAME}) -> ${DIR_A}"
sudo "${BUILD_SCRIPT}" --profile "${PROFILE_NAME}" --output-dir "${DIR_A}"

log_step "Build B (${PROFILE_NAME}) -> ${DIR_B}"
sudo "${BUILD_SCRIPT}" --profile "${PROFILE_NAME}" --output-dir "${DIR_B}"

# ---------------------------------------------------------------------------
# Compare recorded digests
# ---------------------------------------------------------------------------
log_step "Comparing image digests"
DIGEST_A="$(jq -r .output.digest "${DIR_A}/container-manifest.json")"
DIGEST_B="$(jq -r .output.digest "${DIR_B}/container-manifest.json")"
test -n "${DIGEST_A}" -a -n "${DIGEST_B}" \
    || { log_error "Empty digest in a manifest - refusing to compare."; exit 1; }
log_info "Build A digest: ${DIGEST_A}"
log_info "Build B digest: ${DIGEST_B}"

if [[ "${DIGEST_A}" == "${DIGEST_B}" ]]; then
    RESULT="MATCH"
    log_success "DOUBLE_BUILD_MATCH - reproducible given a frozen package set."
    exit 0
fi

RESULT="DIFFER"
log_error "DOUBLE_BUILD_DIFFER - same commit, same day, different image."
log_error "Prime suspect from experience: gzip timestamps in layer blobs"
log_error "(tar/mtime pinning does not reach inside the compressor)."
log_error "Next step (diffoscope-minimal suffices for tar+gzip+JSON):"
log_error "  diffoscope ${DIR_A}/*.oci.tar ${DIR_B}/*.oci.tar"
exit 1
