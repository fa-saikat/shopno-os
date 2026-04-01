#!/usr/bin/env bash
# =============================================================================
# scripts/build/inject-packages.sh
# ShopnoOS — Package List Injector
#
# USAGE:
#   ./scripts/build/inject-packages.sh <profile-name> <lb-config-dir>
#
# PURPOSE:
#   Symlinks all *.list.chroot files from the active profile's layers
#   into the live-build config/package-lists/ directory.
#
# Composition order (all layers injected, lb installs everything):
#   1. base/package-lists/
#   2. editions/<edition>/package-lists/
#   3. flavors/<flavor>/package-lists/     (skipped if flavor=none)
#   4. hardware/<hardware>/package-lists/  (skipped if hardware=generic)
#
# NAMING CONVENTION:
#   Source files must be named: shopno-os-<layer>-<purpose>.list.chroot
#   Symlinks preserve the original filename — no renaming.
#
# DUPLICATE DETECTION:
#   If two layers provide the same filename, this script fails loudly.
#   Resolve the conflict by renaming one of the files.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/profile.sh
source "${LIB_DIR}/profile.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PROFILE_NAME="${1:-}"
LB_CONFIG_DIR="${2:-}"

[[ -z "${PROFILE_NAME}"  ]] && { log_error "Usage: $0 <profile-name> <lb-config-dir>"; exit 1; }
[[ -z "${LB_CONFIG_DIR}" ]] && { log_error "Usage: $0 <profile-name> <lb-config-dir>"; exit 1; }

# Brand already loaded via common → brand chain
# Load profile to get DISTRO_EDITION, DISTRO_FLAVOR, DISTRO_HARDWARE
load_profile "${PROFILE_NAME}"

# ---------------------------------------------------------------------------
# Destination
# ---------------------------------------------------------------------------
PKG_LIST_DEST="${LB_CONFIG_DIR}/package-lists"
mkdir -p "${PKG_LIST_DEST}"

log_step "Injecting package lists into: ${PKG_LIST_DEST}"

# ---------------------------------------------------------------------------
# Track injected filenames to detect collisions
# ---------------------------------------------------------------------------
declare -A INJECTED_FILES   # filename → source path

# _inject_layer "source-dir" "label"
_inject_layer() {
    local src_dir="${1}/package-lists"
    local label="${2}"

    if [[ ! -d "${src_dir}" ]]; then
        log_debug "No package-lists dir for ${label} — skipping."
        return 0
    fi

    local count=0
    while IFS= read -r -d '' list_file; do
        local filename
        filename="$(basename "${list_file}")"

        # Enforce naming convention: must start with 'shopno-os-'
        if ! [[ "${filename}" =~ ^shopno-os- ]]; then
            log_error "Package list does not follow naming convention: ${list_file}"
            log_error "  All lists must be named: shopno-os-<layer>-<purpose>.list.chroot"
            exit 1
        fi

        # Collision check
        if [[ -n "${INJECTED_FILES[${filename}]:-}" ]]; then
            log_error "Package list filename collision detected!"
            log_error "  Filename  : ${filename}"
            log_error "  First seen: ${INJECTED_FILES[${filename}]}"
            log_error "  Conflict  : ${list_file}"
            log_error ""
            log_error "  Two layers cannot provide a file with the same name."
            log_error "  Rename one of them to resolve the conflict."
            exit 1
        fi

        INJECTED_FILES["${filename}"]="${list_file}"

        # Create symlink
        local dest="${PKG_LIST_DEST}/${filename}"
        _symlink "${list_file}" "${dest}"
        (( count++ )) || true
        log_debug "  Injected: ${filename} (← ${label})"

    done < <(find "${src_dir}" -maxdepth 1 -name "*.list.*" -print0 | sort -z) # <-- NOTE

    if [[ "${count}" -gt 0 ]]; then
        log_info "  ${label}: ${count} package list(s) injected"
    else
        log_warn "  ${label}: package-lists/ directory exists but contains no *.list.chroot files"
    fi
}

# ---------------------------------------------------------------------------
# Inject layers in composition order
# ---------------------------------------------------------------------------
_inject_layer "${OS_REPO_ROOT}/base"                           "base"
_inject_layer "${OS_REPO_ROOT}/editions/${DISTRO_EDITION}"     "edition/${DISTRO_EDITION}"

if profile_has_flavor; then
    _inject_layer "${OS_REPO_ROOT}/flavors/${DISTRO_FLAVOR}"   "flavor/${DISTRO_FLAVOR}"
fi

if profile_has_hardware_overlay; then
    _inject_layer "${OS_REPO_ROOT}/hardware/${DISTRO_HARDWARE}" "hardware/${DISTRO_HARDWARE}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL="${#INJECTED_FILES[@]}"
log_success "Package injection complete: ${TOTAL} list(s) active for profile '${PROFILE_NAME}'"

if [[ "${SHOPNOOS_DEBUG:-0}" == "1" ]]; then
    log_debug "Active package lists:"
    find "${PKG_LIST_DEST}" -name "*.list.*" | sort | while IFS= read -r f; do
        log_debug "  $(basename "${f}") → $(readlink -f "${f}")"
    done # <-- NOTE
fi
