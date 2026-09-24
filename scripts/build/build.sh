#!/usr/bin/env bash
# =============================================================================
# scripts/build/build.sh
# ShopnoOS - MAIN BUILD ENTRY POINT
#
# USAGE:
#   ./scripts/build/build.sh <profile-name> [options]
#
# EXAMPLES:
#   ./scripts/build/build.sh shopno-os-core
#   ./scripts/build/build.sh shopno-os-desktop-gnome
#   ./scripts/build/build.sh shopno-os-pro-kde --no-clean
#   ./scripts/build/build.sh shopno-os-core --dry-run
#
# OPTIONS:
#   --no-clean      Skip wiping build/ before starting (faster, uses cache)
#   --dry-run       Print what would happen, do not execute lb build
#   --skip-lint     Skip the package lint check (not recommended)
#   --skip-sign     Skip GPG signing after build
#   --jobs N        Parallel jobs for lb build (default: nproc)
#   --output-dir D  Directory to move final ISO to (default: ./build/output/)
#
# PRECONDITIONS (run before Step 1, unnumbered):
#   - Validate environment (root, live-build, dependencies)
#   - Load brand identity + build profile
#
# PIPELINE STAGES (logged as Step 1/8 - 8/8):
#   1. Lint package lists
#   2. Clean previous build (unless --no-clean)
#   3. Prepare live-build config tree
#   4. Inject package lists via symlinks
#   5. Run lb build
#   6. Stamp ISO with metadata
#   7. Sign ISO + generate checksums (unless --skip-sign)
#   8. Move ISO to output dir
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Bootstrap: resolve repo root and source libs
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/brand.sh
source "${LIB_DIR}/brand.sh"
# shellcheck source=../lib/iso-name.sh
source "${LIB_DIR}/iso-name.sh"
# shellcheck source=../lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROFILE_NAME=""
OPT_NO_CLEAN=0
OPT_DRY_RUN=0
OPT_SKIP_LINT=0
OPT_SKIP_SIGN=0
OPT_JOBS="$(nproc)"
OPT_OUTPUT_DIR="${OS_REPO_ROOT}/build/output"

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <profile-name> [options]

Options:
  --no-clean       Skip wiping build/ before starting
  --dry-run        Print plan, do not build
  --skip-lint      Skip duplicate package check
  --skip-sign      Skip GPG signing
  --jobs N         Parallel jobs (default: nproc = $(nproc))
  --output-dir D   Move final ISO here (default: build/output/)
  -h, --help       Show this help

Available profiles:
$(list_profiles 2>/dev/null | sed 's/^/  /' || echo "  (run from repo root to list)")
EOF
    exit 1
}

[[ $# -eq 0 ]] && _usage

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --no-clean)     OPT_NO_CLEAN=1    ;;
        --dry-run)      OPT_DRY_RUN=1     ;;
        --skip-lint)    OPT_SKIP_LINT=1   ;;
        --skip-sign)    OPT_SKIP_SIGN=1   ;;
        --jobs)         OPT_JOBS="${2}"; shift ;;
        --output-dir)   OPT_OUTPUT_DIR="${2}"; shift ;;
        -h|--help)      _usage ;;
        -*)             log_error "Unknown option: ${1}"; _usage ;;
        *)
            [[ -n "${PROFILE_NAME}" ]] && { log_error "Multiple profile names given."; _usage; }
            PROFILE_NAME="${1}"
            ;;
    esac
    shift
done

[[ -z "${PROFILE_NAME}" ]] && { log_error "Profile name is required."; _usage; }

# ---------------------------------------------------------------------------
# Source profile (brand already loaded above)
# ---------------------------------------------------------------------------
# shellcheck source=../lib/profile.sh
source "${LIB_DIR}/profile.sh"
load_profile "${PROFILE_NAME}"

# ---------------------------------------------------------------------------
# Load secrets and print capability summary
# ---------------------------------------------------------------------------
load_secrets

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
BUILD_DIR="${OS_REPO_ROOT}/build/${PROFILE_NAME}"
LB_CONFIG_DIR="${BUILD_DIR}/config"
ISO_FILENAME="$(iso_name)"
ISO_STEM="$(iso_stem)"

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
log_step "Validating build environment"

require_root
require_command lb live-build debootstrap xorriso mksquashfs gpg jq

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_warn "DRY RUN - no files will be modified."
fi

log_info "Profile      : ${PROFILE_NAME}"
log_info "Edition      : ${DISTRO_EDITION}"
log_info "Flavor       : ${DISTRO_FLAVOR}"
log_info "Hardware     : ${DISTRO_HARDWARE}"
log_info "Arch         : ${DISTRO_ARCH}"
log_info "Distribution : ${LB_DISTRIBUTION}"
log_info "ISO name     : ${ISO_FILENAME}"
log_info "Build dir    : ${BUILD_DIR}"
log_info "Output dir   : ${OPT_OUTPUT_DIR}"
log_info "Jobs         : ${OPT_JOBS}"

# ---------------------------------------------------------------------------
# Pin SOURCE_DATE_EPOCH for reproducible timestamps (Phase 1, sets up
# Phase 6). live-build honors it for image metadata and iso-name.sh
# already honors it for the build date. The HEAD commit timestamp is the
# build's canonical clock: rebuilding the same commit later reproduces
# the same stamps instead of "now". An explicit env value wins, so
# release tooling can pin a date deliberately.
# ---------------------------------------------------------------------------
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    export SOURCE_DATE_EPOCH="$(git -C "${OS_REPO_ROOT}" log -1 --pretty=%ct)"
fi
log_info "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}"

# ---------------------------------------------------------------------------
# Step 1: Lint package lists
# ---------------------------------------------------------------------------
if [[ "${OPT_SKIP_LINT}" -eq 0 ]]; then
    log_step "Step 1/8 - Linting package lists"
    if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
        _run "${SCRIPT_DIR}/../dev/lint-packages.sh"
    else
        log_warn "[dry-run] Would run: lint-packages.sh"
    fi
else
    log_warn "Package lint skipped (--skip-lint)"
fi

# ---------------------------------------------------------------------------
# Step 2: Clean previous build
# ---------------------------------------------------------------------------
log_step "Step 2/8 - Cleaning previous build"
if [[ "${OPT_NO_CLEAN}" -eq 0 ]]; then
    if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
        _run "${SCRIPT_DIR}/clean.sh" "${PROFILE_NAME}"
    else
        log_warn "[dry-run] Would run: clean.sh ${PROFILE_NAME}"
    fi
else
    log_warn "Clean skipped (--no-clean) - using cached state in ${BUILD_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 3: Prepare live-build config tree
# ---------------------------------------------------------------------------
log_step "Step 3/8 - Preparing live-build config"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    _run "${SCRIPT_DIR}/prepare-lb-config.sh" "${PROFILE_NAME}" "${BUILD_DIR}"
else
    log_warn "[dry-run] Would run: prepare-lb-config.sh ${PROFILE_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 4: Inject package lists
# ---------------------------------------------------------------------------
log_step "Step 4/8 - Injecting package lists"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    _run "${SCRIPT_DIR}/inject-packages.sh" "${PROFILE_NAME}" "${LB_CONFIG_DIR}"
else
    log_warn "[dry-run] Would run: inject-packages.sh ${PROFILE_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 5: Run lb build
# ---------------------------------------------------------------------------
log_step "Step 5/8 - Running lb build"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    pushd "${BUILD_DIR}" > /dev/null
        log_info "Working directory: $(pwd)"
        _run lb build 2>&1 \
            | tee "${BUILD_DIR}/build.log"
        LB_EXIT="${PIPESTATUS[0]}"
    popd > /dev/null

    if [[ "${LB_EXIT}" -ne 0 ]]; then
        log_error "lb build failed with exit code ${LB_EXIT}."
        log_error "Check the build log: ${BUILD_DIR}/build.log"
        exit "${LB_EXIT}"
    fi
    log_success "lb build completed successfully."
else
    log_warn "[dry-run] Would run: lb build --jobs ${OPT_JOBS} (in ${BUILD_DIR})"
fi

# ---------------------------------------------------------------------------
# Step 6: Stamp ISO
# ---------------------------------------------------------------------------
log_step "Step 6/8 - Stamping ISO with build metadata"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    _run "${SCRIPT_DIR}/stamp-iso.sh" "${BUILD_DIR}" "${ISO_FILENAME}"
else
    log_warn "[dry-run] Would run: stamp-iso.sh"
fi

# ---------------------------------------------------------------------------
# Step 7: Sign ISO + generate checksums
# ---------------------------------------------------------------------------
log_step "Step 7/8 - Signing and checksumming"
if [[ "${OPT_SKIP_SIGN}" -eq 0 ]]; then
    if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
        _run "${SCRIPT_DIR}/../release/sign-iso.sh" \
            "${BUILD_DIR}/${ISO_FILENAME}"
    else
        log_warn "[dry-run] Would run: sign-iso.sh ${ISO_FILENAME}"
    fi
else
    log_warn "Signing skipped (--skip-sign)"
fi

# ---------------------------------------------------------------------------
# Step 8: Move to output directory
# ---------------------------------------------------------------------------
log_step "Step 8/8 - Moving ISO to output directory"
if [[ "${OPT_DRY_RUN}" -eq 0 ]]; then
    mkdir -p "${OPT_OUTPUT_DIR}"
    for artifact in \
        "${BUILD_DIR}/${ISO_FILENAME}" \
        "${BUILD_DIR}/$(iso_checksum_filename sha256)" \
        "${BUILD_DIR}/$(iso_checksum_filename sha512)" \
        "${BUILD_DIR}/$(iso_signature_filename)" \
        "${BUILD_DIR}/build-manifest.json"
    do
        if [[ -f "${artifact}" ]]; then
            mv "${artifact}" "${OPT_OUTPUT_DIR}/"
            log_info "  → $(basename "${artifact}")"
        fi
    done
    log_success "Artifacts written to: ${OPT_OUTPUT_DIR}"
else
    log_warn "[dry-run] Would move artifacts to: ${OPT_OUTPUT_DIR}"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_step "BUILD COMPLETE"
log_success "ISO: ${OPT_OUTPUT_DIR}/${ISO_FILENAME}"
log_info "Total build time: $((SECONDS / 60))m $((SECONDS % 60))s"
