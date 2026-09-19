#!/usr/bin/env bash
# =============================================================================
# tests/smoke/test-packages-present.sh
# ShopnoOS - Package Presence Smoke Test (Phase 2 boot gate, part 2)
#
# PURPOSE:
#   Verifies a built ISO actually contains what its layers declared, by
#   inspecting the ARTIFACT (not the source lists — that's lint's job):
#     1. Extract the ISO rootlessly (xorriso) — no loop mounts, no root.
#     2. Locate filesystem.squashfs inside the extracted tree.
#     3. Extract var/lib/dpkg/status from the squashfs rootlessly
#        (unsquashfs single-file extract) and parse installed Package: names.
#     4. Compare against tests/fixtures/expected-package-counts.json:
#        - every critical_packages[] entry for the profile must be present
#        - installed count must be >= total_min (floor, not exact — tolerant
#          of upstream Debian dependency churn)
#
#   Floor + critical-list (not exact counts) is a deliberate choice: exact
#   counts go stale on every upstream change and train people to bump
#   numbers blindly. A floor catches catastrophic drops; the critical list
#   catches layer-merge regressions deterministically.
#
# USAGE:
#   ./tests/smoke/test-packages-present.sh <path/to/iso> [options]
#
# OPTIONS:
#   --profile NAME      Override profile detection (e.g. shopno-os-core).
#                       Default: derived from /.shopno-os-build-info inside
#                       the ISO, else build-manifest.json sibling, else the
#                       ISO filename.
#   --fixture PATH      Fixture file (default: tests/fixtures/expected-package-counts.json)
#   --squashfs PATH     Skip ISO extraction; use this squashfs directly.
#                       (Useful for testing without a full ISO.)
#   --dpkg-status PATH  Skip ISO+squashfs entirely; parse this dpkg status
#                       file directly. (Useful for synthetic/negative tests.)
#   --keep-workdir      Don't delete the temp extraction dir on exit.
#   --workdir DIR       Use DIR as workdir instead of mktemp (implies --keep-workdir).
#   -h, --help          Show this help.
#
# HOST DEPS (all rootless): xorriso, unsquashfs (squashfs-tools), jq,
#   plus 7z (p7zip, optional) as extraction fallback for images whose
#   tree xorriso 1.5.x cannot parse (e.g. >4GB squashfs members).
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
Usage: $(basename "$0") <path/to/iso> [options]

Options:
  --profile NAME      Override profile detection (e.g. shopno-os-core)
  --fixture PATH      Fixture file (default: tests/fixtures/expected-package-counts.json)
  --squashfs PATH     Use this squashfs directly, skip ISO extraction
  --dpkg-status PATH  Parse this dpkg status file directly, skip ISO+squashfs
  --keep-workdir      Don't delete the temp extraction dir on exit
  --workdir DIR       Use DIR as workdir (implies --keep-workdir)
  -h, --help          Show this help
EOF
    exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && _usage
[[ $# -eq 0 ]] && _usage

ISO_PATH="${1:-}"
OPT_PROFILE=""
OPT_FIXTURE="${SCRIPT_DIR}/../fixtures/expected-package-counts.json"
OPT_SQUASHFS=""
OPT_DPKG_STATUS=""
OPT_KEEP_WORKDIR=0
OPT_WORKDIR=""
shift || true

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile)     OPT_PROFILE="${2}"; shift ;;
        --fixture)     OPT_FIXTURE="${2}"; shift ;;
        --squashfs)    OPT_SQUASHFS="${2}"; shift ;;
        --dpkg-status) OPT_DPKG_STATUS="${2}"; shift ;;
        --keep-workdir) OPT_KEEP_WORKDIR=1 ;;
        --workdir)     OPT_WORKDIR="${2}"; OPT_KEEP_WORKDIR=1; shift ;;
        -h|--help)     _usage ;;
        *) log_error "Unknown option: ${1}"; _usage ;;
    esac
    shift
done

require_file "${ISO_PATH}" "${OPT_FIXTURE}"
require_command jq

# ---------------------------------------------------------------------------
# Workdir
# ---------------------------------------------------------------------------
if [[ -n "${OPT_WORKDIR}" ]]; then
    WORKDIR="${OPT_WORKDIR}"
    mkdir -p "${WORKDIR}"
else
    WORKDIR="$(mktemp -d /tmp/shopno-os-pkg-test.XXXXXX)"
fi

if [[ "${OPT_KEEP_WORKDIR}" -eq 0 ]]; then
    # xorriso restores ISO permissions verbatim (read-only files AND dirs),
    # so plain `rm -rf` fails — make everything writable first.
    _cleanup_workdir() {
        chmod -R u+rwX "${WORKDIR}" 2>/dev/null || true
        rm -rf "${WORKDIR}" 2>/dev/null || true
    }
    trap '_cleanup_workdir' EXIT
else
    trap 'log_info "Workdir kept at: ${WORKDIR}"' EXIT
fi

# ---------------------------------------------------------------------------
# Step 1: obtain var/lib/dpkg/status rootlessly
# ---------------------------------------------------------------------------
STATUS_FILE=""

if [[ -n "${OPT_DPKG_STATUS}" ]]; then
    # Fast path: caller handed us a status file (synthetic tests).
    require_file "${OPT_DPKG_STATUS}"
    STATUS_FILE="${OPT_DPKG_STATUS}"
    log_info "Using supplied dpkg status file: ${STATUS_FILE}"
else
    SQUASHFS=""
    if [[ -n "${OPT_SQUASHFS}" ]]; then
        require_file "${OPT_SQUASHFS}"
        SQUASHFS="${OPT_SQUASHFS}"
    else
        # Extract ISO rootlessly (no loop mount, no root). xorriso first
        # (already a repo dependency via stamp-iso.sh); 7z as fallback —
        # xorriso 1.5.x cannot parse trees containing >4GB files (multi-
        # extent SUSP CE areas), which large squashfs images hit.
        # NOTE: xorriso 1.5.x dialect is `-osirrox on -extract / DEST --`;
        # `-osirx` only exists in newer releases. Keep the old form.
        require_command xorriso unsquashfs
        ISO_ROOT="${WORKDIR}/iso"
        mkdir -p "${ISO_ROOT}"
        log_step "Extracting ISO (rootless): $(basename "${ISO_PATH}")"
        XORRISO_LOG="${WORKDIR}/xorriso.log"
        if xorriso -indev "${ISO_PATH}" -osirrox on -extract / "${ISO_ROOT}" -- > "${XORRISO_LOG}" 2>&1; then
            log_info "Extracted with xorriso"
        elif command -v 7z > /dev/null 2>&1; then
            log_warn "xorriso extraction failed — falling back to 7z"
            tail -5 "${XORRISO_LOG}" >&2 || true
            # xorriso may have died partway, leaving a partially-extracted
            # read-only tree (it restores ISO permissions verbatim). 7z must
            # overwrite those same paths, so start it from a clean dir —
            # otherwise the fallback fails on the very images it exists for.
            chmod -R u+rwX "${ISO_ROOT}" 2>/dev/null || true
            rm -rf "${ISO_ROOT}"
            mkdir -p "${ISO_ROOT}"
            P7ZIP_LOG="${WORKDIR}/7z.log"
            if ! 7z x "-o${ISO_ROOT}" "${ISO_PATH}" > "${P7ZIP_LOG}" 2>&1; then
                log_error "7z extraction also failed for: ${ISO_PATH}"
                tail -10 "${P7ZIP_LOG}" >&2 || true
                exit 1
            fi
            log_info "Extracted with 7z"
        else
            log_error "xorriso extraction failed for: ${ISO_PATH} (no 7z fallback available)"
            log_error "Last output:"
            tail -10 "${XORRISO_LOG}" >&2 || true
            exit 1
        fi

        # Profile hint #1: embedded build info (written by stamp-iso.sh).
        BUILD_INFO="${ISO_ROOT}/.shopno-os-build-info"
        [[ -f "${BUILD_INFO}" ]] && log_info "Found embedded build info: /.shopno-os-build-info"

        # Locate the squashfs (live-build: live/filesystem.squashfs).
        SQUASHFS="$(find "${ISO_ROOT}" -name '*.squashfs' 2>/dev/null | sort | head -1 || true)"
        [[ -n "${SQUASHFS}" ]] \
            || { log_error "No *.squashfs found inside ISO: ${ISO_PATH}"; exit 1; }
        log_info "Squashfs: ${SQUASHFS}"
    fi

    # Single-file extract of the dpkg database — no full unsquash, no root.
    require_command unsquashfs
    ROOT_EXTRACT="${WORKDIR}/root"
    mkdir -p "${ROOT_EXTRACT}"
    log_step "Extracting dpkg status from squashfs (rootless)"
    if ! unsquashfs -f -d "${ROOT_EXTRACT}" "${SQUASHFS}" var/lib/dpkg/status > /dev/null 2>&1; then
        # Some images store it with a leading ./ — retry explicitly.
        unsquashfs -f -d "${ROOT_EXTRACT}" "${SQUASHFS}" ./var/lib/dpkg/status > /dev/null 2>&1 \
            || { log_error "var/lib/dpkg/status not found in squashfs: ${SQUASHFS}"; exit 1; }
    fi
    STATUS_FILE="$(find "${ROOT_EXTRACT}" -path '*var/lib/dpkg/status' 2>/dev/null | head -1)"
    [[ -n "${STATUS_FILE}" && -f "${STATUS_FILE}" ]] \
        || { log_error "dpkg status extract produced no file (squashfs: ${SQUASHFS})"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Step 2: parse installed package set
# ---------------------------------------------------------------------------
INSTALLED_LIST="${WORKDIR}/installed-packages.txt"
grep -E '^Package: ' "${STATUS_FILE}" | awk '{print $2}' | sort -u > "${INSTALLED_LIST}"
INSTALLED_COUNT="$(wc -l < "${INSTALLED_LIST}" | tr -d ' ')"
log_info "Installed packages found: ${INSTALLED_COUNT}"
[[ "${INSTALLED_COUNT}" -gt 0 ]] \
    || { log_error "Parsed zero packages from: ${STATUS_FILE} — refusing to pass an empty set"; exit 1; }

# ---------------------------------------------------------------------------
# Step 3: resolve profile identity
# ---------------------------------------------------------------------------
PROFILE="${OPT_PROFILE}"

if [[ -z "${PROFILE}" ]]; then
    # Hint 1: embedded build info inside the ISO (if we extracted one).
    # Keys are OS_ISO_* — see iso_metadata_env() in scripts/lib/iso-name.sh.
    if [[ -z "${PROFILE}" && -n "${BUILD_INFO:-}" && -f "${BUILD_INFO}" ]]; then
        # shellcheck disable=SC1090
        ED="" FL="" HW=""
        ED="$(grep -E '^OS_ISO_EDITION=' "${BUILD_INFO}" | cut -d= -f2 | tr -d '"' || true)"
        FL="$(grep -E '^OS_ISO_FLAVOR=' "${BUILD_INFO}" | cut -d= -f2 | tr -d '"' || true)"
        HW="$(grep -E '^OS_ISO_HARDWARE=' "${BUILD_INFO}" | cut -d= -f2 | tr -d '"' || true)"
        if [[ -n "${ED}" && -n "${FL}" ]]; then
            PROFILE="shopno-os-${ED}-${FL}"
            [[ "${HW:-generic}" != "generic" && -n "${HW:-}" ]] && PROFILE="${PROFILE}-${HW}"
            log_info "Profile from /.shopno-os-build-info: ${PROFILE}"
        fi
    fi
    # Hint 2: build-manifest.json next to the ISO (written by stamp-iso.sh).
    if [[ -z "${PROFILE}" ]]; then
        MANIFEST="$(dirname "${ISO_PATH}")/build-manifest.json"
        if [[ -f "${MANIFEST}" ]]; then
            ED="$(jq -r '.build.edition // empty' "${MANIFEST}" 2>/dev/null || true)"
            FL="$(jq -r '.build.flavor // empty' "${MANIFEST}" 2>/dev/null || true)"
            HW="$(jq -r '.build.hardware // "generic"' "${MANIFEST}" 2>/dev/null || true)"
            if [[ -n "${ED}" && -n "${FL}" ]]; then
                PROFILE="shopno-os-${ED}-${FL}"
                [[ "${HW}" != "generic" ]] && PROFILE="${PROFILE}-${HW}"
                log_info "Profile from build-manifest.json: ${PROFILE}"
            fi
        fi
    fi
    # Hint 3: ISO filename heuristic per the Naming Law
    # (<prefix>-<version>-<edition>-<flavor>-<arch>-<date>[-<hw>].iso —
    # see _build_iso_stem() in scripts/lib/iso-name.sh). The version field
    # MUST be consumed explicitly: it sits between prefix and edition, so
    # matching [a-z]+ right after the prefix can never hit a real filename.
    # Flavor allows one hyphen segment (e.g. minimal-x); hw suffix appended
    # only when present (non-generic).
    if [[ -z "${PROFILE}" ]]; then
        BASE="$(basename "${ISO_PATH}" .iso)"
        if [[ "${BASE}" =~ ^shopno-os-[0-9]+(\.[0-9]+)*-([a-z]+)-([a-z0-9]+(-[a-z0-9]+)?)-([a-z0-9]+)-([0-9]{8})(-([a-z0-9]+))?$ ]]; then
            PROFILE="shopno-os-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            [[ -n "${BASH_REMATCH[8]:-}" ]] && PROFILE="${PROFILE}-${BASH_REMATCH[8]}"
            log_warn "Profile guessed from filename: ${PROFILE} (pass --profile to override)"
        fi
    fi
fi

# Normalize: flavor 'none' is not part of profile names (profiles/shopno-os-core,
# not shopno-os-core-none), but it does appear in build-info, manifest and ISO
# filenames. Strip it here, once, for every detection hint uniformly.
PROFILE="${PROFILE//-none-/-}"
PROFILE="${PROFILE%-none}"

[[ -n "${PROFILE}" ]] \
    || { log_error "Could not determine profile — pass --profile explicitly"; exit 1; }
log_info "Profile under test: ${PROFILE}"

# ---------------------------------------------------------------------------
# Step 4: load expectations from fixture
# ---------------------------------------------------------------------------
if ! jq -e ".profiles[\"${PROFILE}\"]" "${OPT_FIXTURE}" > /dev/null 2>&1; then
    log_error "Profile '${PROFILE}' not found in fixture: ${OPT_FIXTURE}"
    log_error "Available: $(jq -r '.profiles | keys | join(", ")' "${OPT_FIXTURE}" 2>/dev/null || echo '?')"
    exit 1
fi

TOTAL_MIN="$(jq -r ".profiles[\"${PROFILE}\"].total_min" "${OPT_FIXTURE}")"
mapfile -t CRITICAL < <(jq -r ".profiles[\"${PROFILE}\"].critical_packages[]?" "${OPT_FIXTURE}")

[[ "${TOTAL_MIN}" =~ ^[0-9]+$ ]] \
    || { log_error "Fixture total_min for '${PROFILE}' is not a number: ${TOTAL_MIN}"; exit 1; }
[[ "${#CRITICAL[@]}" -gt 0 ]] \
    || { log_error "Fixture critical_packages for '${PROFILE}' is empty — refusing to pass vacuously"; exit 1; }

log_info "Expectations: total_min=${TOTAL_MIN}, critical=${#CRITICAL[@]} packages"

# ---------------------------------------------------------------------------
# Step 5: evaluate
# ---------------------------------------------------------------------------
FAILED=0

if [[ "${INSTALLED_COUNT}" -lt "${TOTAL_MIN}" ]]; then
    log_error "FAIL: installed count ${INSTALLED_COUNT} below floor ${TOTAL_MIN} (profile: ${PROFILE})"
    FAILED=1
else
    log_info "Count check passed: ${INSTALLED_COUNT} >= ${TOTAL_MIN}"
fi

MISSING=()
for pkg in "${CRITICAL[@]}"; do
    [[ -z "${pkg}" ]] && continue
    if ! grep -qxF "${pkg}" "${INSTALLED_LIST}"; then
        MISSING+=("${pkg}")
    fi
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    log_error "FAIL: ${#MISSING[@]} critical package(s) missing (profile: ${PROFILE}):"
    for pkg in "${MISSING[@]}"; do
        log_error "  - ${pkg}"
    done
    FAILED=1
else
    log_info "Critical-package check passed: all ${#CRITICAL[@]} present"
fi

if [[ "${FAILED}" -eq 1 ]]; then
    log_error "Package presence test FAILED: $(basename "${ISO_PATH}") [${PROFILE}]"
    exit 1
fi

log_success "Package presence test PASSED: $(basename "${ISO_PATH}") [${PROFILE}] (${INSTALLED_COUNT} installed, ${#CRITICAL[@]} critical OK)"
exit 0
