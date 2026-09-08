#!/usr/bin/env bash
# =============================================================================
# scripts/build/clean.sh
# ShopnoOS - Build Artifact Cleaner
#
# USAGE:
#   ./scripts/build/clean.sh <profile-name>   # clean one profile's build dir
#   ./scripts/build/clean.sh --all            # clean all profile build dirs
#   ./scripts/build/clean.sh --cache          # also wipe lb cache (full reset)
#
# WHAT IT CLEANS:
#   - build/<profile>/         (live-build working directories + log)
#   - Optionally: build/cache/ (debootstrap + package cache)
#
# WHAT IT NEVER TOUCHES:
#   - build/output/            (final ISOs - protected)
#   - brand/, editions/, flavors/, hardware/, base/
#   - Any source files
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_PROFILE=""
OPT_ALL=0
OPT_CACHE=0
OPT_FORCE=0

_usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") <profile-name>   Clean build dir for one profile
  $(basename "$0") --all            Clean all profile build dirs
  $(basename "$0") --cache          Also wipe the lb package cache

Options:
  --force    Skip confirmation prompt
  -h, --help Show this help
EOF
    exit 1
}

[[ $# -eq 0 ]] && _usage

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --all)          OPT_ALL=1    ;;
        --cache)        OPT_CACHE=1  ;;
        --force)        OPT_FORCE=1  ;;
        -h|--help)      _usage       ;;
        -*)             log_error "Unknown option: ${1}"; _usage ;;
        *)
            [[ -n "${TARGET_PROFILE}" ]] && { log_error "Multiple profile names given."; _usage; }
            TARGET_PROFILE="${1}"
            ;;
    esac
    shift
done

if [[ -z "${TARGET_PROFILE}" && "${OPT_ALL}" -eq 0 ]]; then
    log_error "Provide a profile name or --all."
    _usage
fi

# ---------------------------------------------------------------------------
# Resolve targets
# ---------------------------------------------------------------------------
BUILD_ROOT="${OS_REPO_ROOT}/build"
OUTPUT_DIR="${BUILD_ROOT}/output"
CACHE_DIR="${BUILD_ROOT}/cache"

declare -a TARGETS=()

if [[ "${OPT_ALL}" -eq 1 ]]; then
    while IFS= read -r -d '' d; do
        local_name="$(basename "${d}")"
        # Never touch output/ or cache/
        [[ "${local_name}" == "output" || "${local_name}" == "cache" ]] && continue
        TARGETS+=("${d}")
    done < <(find "${BUILD_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
else
    TARGETS+=("${BUILD_ROOT}/${TARGET_PROFILE}")
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    log_info "Nothing to clean - no build directories found in ${BUILD_ROOT}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Confirm (unless --force)
# ---------------------------------------------------------------------------
if [[ "${OPT_FORCE}" -eq 0 ]]; then
    log_warn "The following directories will be removed:"
    for t in "${TARGETS[@]}"; do
        log_warn "  ${t}"
    done
    [[ "${OPT_CACHE}" -eq 1 ]] && log_warn "  ${CACHE_DIR}  (cache)"
    confirm "Proceed?" || { log_info "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Clean live-build state inside each target (lb clean is safer than rm -rf)
# ---------------------------------------------------------------------------
for target_dir in "${TARGETS[@]}"; do
    if [[ ! -d "${target_dir}" ]]; then
        log_debug "Directory does not exist, skipping: ${target_dir}"
        continue
    fi

    log_step "Cleaning: ${target_dir}"

    if [[ -f "${target_dir}/.build/binary" || -d "${target_dir}/chroot" ]]; then
        # live-build has partially or fully run - use lb clean
        pushd "${target_dir}" > /dev/null
            log_info "Running lb clean --purge inside ${target_dir}"
            lb clean --purge 2>/dev/null || true
        popd > /dev/null
    fi

    # Wipe contents, then remove the directory itself
    find "${target_dir}" -mindepth 1 -delete 2>/dev/null || true
    rmdir "${target_dir}" 2>/dev/null || true
    log_success "Removed: ${target_dir}"
done

# ---------------------------------------------------------------------------
# Optional: wipe package cache
# ---------------------------------------------------------------------------
if [[ "${OPT_CACHE}" -eq 1 ]]; then
    log_step "Wiping lb cache: ${CACHE_DIR}"
    if [[ -d "${CACHE_DIR}" ]]; then
        rm -rf "${CACHE_DIR:?}"/*
        log_success "Cache wiped: ${CACHE_DIR}"
    else
        log_info "Cache directory does not exist - nothing to wipe."
    fi
fi

log_success "Clean complete."
