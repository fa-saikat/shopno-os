#!/usr/bin/env bash
# =============================================================================
# scripts/build/clean.sh
# ShopnoOS - Build Artifact Cleaner
#
# USAGE:
#   ./scripts/build/clean.sh <profile-name>   # clean one profile's build dir
#   ./scripts/build/clean.sh --all            # clean all profile build dirs
#   ./scripts/build/clean.sh --cache          # also wipe lb cache (full reset)
#   ./scripts/build/clean.sh --container      # clean container artifacts
#
# WHAT IT CLEANS:
#   - build/<profile>/         (live-build working directories + log)
#   - build/container/         (--container, or as part of --all)
#   - Local buildah shopno-os-container:* images + /tmp workdir strays
#     (--container, or as part of --all; failed/interrupted container
#     builds can leave both behind - the image tarball itself is never
#     enough to assume a clean store)
#   - Optionally: build/cache/ (debootstrap + package cache)
#
# WHAT IT NEVER TOUCHES:
#   - build/output/            (final ISOs - protected)
#   - brand/, editions/, flavors/, hardware/, base/
#   - Any source files
#
# PRIVILEGE: builds run under sudo, so artifacts are usually root-owned.
# A non-root run aborts loudly (naming sudo) instead of half-deleting.
# Success is verified (absence re-checked), never assumed.
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
OPT_CONTAINER=0

_usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") <profile-name>   Clean build dir for one profile
  $(basename "$0") --all            Clean all profile build dirs
  $(basename "$0") --cache          Also wipe the lb package cache
  $(basename "$0") --container      Clean container artifacts (tarball dir,
                                    local buildah images, /tmp strays)

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
        --container)    OPT_CONTAINER=1 ;;
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

if [[ -z "${TARGET_PROFILE}" && "${OPT_ALL}" -eq 0 && "${OPT_CONTAINER}" -eq 0 ]]; then
    log_error "Provide a profile name, --all, or --container."
    _usage
fi

# ---------------------------------------------------------------------------
# Resolve targets
# ---------------------------------------------------------------------------
BUILD_ROOT="${OS_REPO_ROOT}/build"
OUTPUT_DIR="${BUILD_ROOT}/output"
CACHE_DIR="${BUILD_ROOT}/cache"
CONTAINER_DIR="${BUILD_ROOT}/container"

declare -a TARGETS=()

if [[ "${OPT_ALL}" -eq 1 ]]; then
    while IFS= read -r -d '' d; do
        local_name="$(basename "${d}")"
        # Never touch output/ or cache/
        [[ "${local_name}" == "output" || "${local_name}" == "cache" ]] && continue
        TARGETS+=("${d}")
    done < <(find "${BUILD_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
else
    # Guard the empty-profile case (--container alone): without it this
    # resolves to build/ itself and the loop below would wipe everything,
    # including the protected output/ dir.
    [[ -n "${TARGET_PROFILE}" ]] && TARGETS+=("${BUILD_ROOT}/${TARGET_PROFILE}")
fi

if [[ ${#TARGETS[@]} -eq 0 && "${OPT_CONTAINER}" -eq 0 ]]; then
    log_info "Nothing to clean - no build directories found in ${BUILD_ROOT}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Privilege gate: builds run under sudo, so artifacts are typically
# root-owned. Every destructive step below used to swallow its own errors
# and report success anyway. Check FIRST - delete nothing on fail.
# (Skipped for root, which can remove everything by definition.)
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    declare -a _CHECK_DIRS=()
    for t in "${TARGETS[@]}"; do
        [[ -d "${t}" ]] && _CHECK_DIRS+=("${t}")
    done
    if [[ "${OPT_CONTAINER}" -eq 1 || "${OPT_ALL}" -eq 1 ]]; then
        [[ -d "${CONTAINER_DIR}" ]] && _CHECK_DIRS+=("${CONTAINER_DIR}")
        log_warn "Note: images built under sudo live in root's buildah store,"
        log_warn "which this run cannot even see - sudo covers those too."
    fi
    declare -a UNOWNED=()
    for d in "${_CHECK_DIRS[@]}"; do
        while IFS= read -r -d '' f; do
            UNOWNED+=("${f}")
            [[ "${#UNOWNED[@]}" -ge 5 ]] && break 2
        done < <(find "${d}" \( ! -user "$(id -un)" -o ! -writable \) -print0 2>/dev/null)
    done
    if [[ "${#UNOWNED[@]}" -gt 0 ]]; then
        log_error "Refusing to clean: root-owned/unwritable files present (builds run under sudo)."
        for f in "${UNOWNED[@]}"; do
            log_error "  ${f}"
        done
        [[ "${#UNOWNED[@]}" -ge 5 ]] && log_error "  ... (truncated - more exist)"
        log_error "Re-run this exact command with sudo."
        exit 1
    fi
fi

FAILED=0

# ---------------------------------------------------------------------------
# Container artifacts: output dir, local buildah store, /tmp strays
# Runs for --container, and as part of --all (the container dir is also
# swept by the generic --all loop above - this covers the store + tmp).
# ---------------------------------------------------------------------------
_clean_container_artifacts() {
    if [[ -d "${CONTAINER_DIR}" ]]; then
        log_step "Cleaning container output: ${CONTAINER_DIR}"
        if ! find "${CONTAINER_DIR}" -mindepth 1 -delete; then
            log_error "Failed to wipe contents: ${CONTAINER_DIR}"
            FAILED=1
        elif ! rmdir "${CONTAINER_DIR}" 2>/dev/null; then
            log_error "Failed to remove directory: ${CONTAINER_DIR}"
            FAILED=1
        elif [[ -e "${CONTAINER_DIR}" ]]; then
            log_error "Directory still exists after wipe: ${CONTAINER_DIR}"
            FAILED=1
        else
            log_success "Removed: ${CONTAINER_DIR}"
        fi
    else
        log_debug "No container output dir - skipping."
    fi

    if command -v buildah > /dev/null 2>&1; then
        mapfile -t LEFTOVER_IMAGES < <(
            buildah images --format '{{.Name}}:{{.Tag}}' 2>/dev/null \
                | grep -E '(^|/)shopno-os-container:' || true
        )
        if [[ "${#LEFTOVER_IMAGES[@]}" -gt 0 ]]; then
            log_step "Removing ${#LEFTOVER_IMAGES[@]} leftover buildah image(s)"
            for img in "${LEFTOVER_IMAGES[@]}"; do
                buildah rmi "${img}" > /dev/null 2>&1 \
                    && log_info "  Removed image: ${img}" \
                    || log_warn "  Could not remove image: ${img}"
            done
        else
            log_debug "No leftover shopno-os-container images."
        fi
    else
        log_debug "buildah not installed - skipping image store cleanup."
    fi

    # Stray mktemp workdirs from interrupted runs (--keep-rootfs ones are
    # announced by the builder itself, so anything here is genuinely stray)
    while IFS= read -r -d '' stray; do
        log_info "Removing stray workdir: ${stray}"
        chmod -R u+rwX "${stray}" 2>/dev/null || true
        if ! rm -rf "${stray:?}" || [[ -e "${stray}" ]]; then
            log_error "Failed to remove stray workdir: ${stray}"
            FAILED=1
        fi
    done < <(find /tmp -maxdepth 1 -type d -name 'shopno-os-container.*' -print0 2>/dev/null)
    if [[ "${FAILED}" -eq 0 ]]; then
        log_success "Container cleanup complete."
    fi
}

# ---------------------------------------------------------------------------
# Confirm (unless --force)
# ---------------------------------------------------------------------------
if [[ "${OPT_FORCE}" -eq 0 ]]; then
    log_warn "The following directories will be removed:"
    for t in "${TARGETS[@]}"; do
        log_warn "  ${t}"
    done
    [[ "${OPT_CACHE}" -eq 1 ]] && log_warn "  ${CACHE_DIR}  (cache)"
    { [[ "${OPT_CONTAINER}" -eq 1 ]] || [[ "${OPT_ALL}" -eq 1 ]]; } && log_warn "  ${CONTAINER_DIR} + buildah shopno-os-container images + /tmp strays  (container)"
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
        # live-build has partially or fully run - use lb clean (best effort;
        # the verified wipe below is what actually guarantees the outcome)
        pushd "${target_dir}" > /dev/null
            log_info "Running lb clean --purge inside ${target_dir}"
            lb clean --purge 2>/dev/null || log_warn "lb clean --purge reported failure - continuing with direct wipe."
        popd > /dev/null
    fi

    # Wipe contents, then remove the directory itself - verified, never assumed
    if ! find "${target_dir}" -mindepth 1 -delete; then
        log_error "Failed to wipe contents: ${target_dir}"
        FAILED=1
        continue
    fi
    if ! rmdir "${target_dir}" 2>/dev/null || [[ -e "${target_dir}" ]]; then
        log_error "Failed to remove directory: ${target_dir}"
        FAILED=1
        continue
    fi
    log_success "Removed: ${target_dir}"
done

# ---------------------------------------------------------------------------
# Container artifacts (explicit --container, or folded into --all)
# ---------------------------------------------------------------------------
if [[ "${OPT_CONTAINER}" -eq 1 || "${OPT_ALL}" -eq 1 ]]; then
    _clean_container_artifacts
fi

# ---------------------------------------------------------------------------
# Optional: wipe package cache
# ---------------------------------------------------------------------------
if [[ "${OPT_CACHE}" -eq 1 ]]; then
    log_step "Wiping lb cache: ${CACHE_DIR}"
    if [[ -d "${CACHE_DIR}" ]]; then
        if rm -rf "${CACHE_DIR:?}"/* && [[ -z "$(ls -A "${CACHE_DIR}" 2>/dev/null)" ]]; then
            log_success "Cache wiped: ${CACHE_DIR}"
        else
            log_error "Cache wipe incomplete: ${CACHE_DIR}"
            FAILED=1
        fi
    else
        log_info "Cache directory does not exist - nothing to wipe."
    fi
fi

if [[ "${FAILED}" -eq 0 ]]; then
    log_success "Clean complete."
else
    log_error "Clean incomplete - see errors above."
    exit 1
fi
