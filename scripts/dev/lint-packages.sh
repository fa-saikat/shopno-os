#!/usr/bin/env bash
# =============================================================================
# scripts/dev/lint-packages.sh
# ShopnoOS — Package List Linter
#
# USAGE:
#   ./scripts/dev/lint-packages.sh              # lint all layers
#   ./scripts/dev/lint-packages.sh --profile shopno-os-desktop-gnome  # one profile
#   ./scripts/dev/lint-packages.sh --strict     # exit 1 on any warning
#
# CHECKS PERFORMED:
#   1. Duplicate packages across lists within the same build (fatal)
#   2. Duplicate packages within a single list file (warning)
#   3. Package name format validation (lowercase, valid chars)
#   4. Naming convention: all lists must start with 'shopno-os-'
#   5. Empty list files (warning)
#   6. Packages that live in the wrong layer (e.g. Xorg in base)
#
# EXIT CODES:
#   0 — all checks passed (warnings may exist)
#   1 — one or more fatal errors found
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
OPT_PROFILE=""
OPT_STRICT=0

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile) OPT_PROFILE="${2}"; shift ;;
        --strict)  OPT_STRICT=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--profile <name>] [--strict]"
            exit 0
            ;;
        *) log_error "Unknown option: ${1}"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
ERRORS=0
WARNINGS=0

_error() { log_error "$*"; (( ERRORS++ ))   || true; }
_warn()  { log_warn  "$*"; (( WARNINGS++ )) || true; }

# ---------------------------------------------------------------------------
# Collect all package list files to lint
# ---------------------------------------------------------------------------

_collect_lists() {
    local profile="${1:-}"
    local -n _out_lists="${2}"   # nameref to output array

    if [[ -n "${profile}" ]]; then
        # Only collect lists relevant to this profile
        # shellcheck source=../lib/profile.sh
        source "${LIB_DIR}/profile.sh"
        # shellcheck source=../lib/brand.sh
        source "${LIB_DIR}/brand.sh"
        load_profile "${profile}"
        while IFS= read -r f; do
            _out_lists+=("${f}")
        done < <(profile_package_lists)
    else
        # Collect every *.list.chroot across the whole repo
        while IFS= read -r -d '' f; do
            _out_lists+=("${f}")
        done < <(find "${OS_REPO_ROOT}" \
            \( -path "${OS_REPO_ROOT}/build" -o \
               -path "${OS_REPO_ROOT}/.git"  \) -prune \
            -o -name "*.list.chroot" -print0 | sort -z)     # <-- NOTE
    fi
}

declare -a ALL_LISTS=()
_collect_lists "${OPT_PROFILE}" ALL_LISTS

if [[ ${#ALL_LISTS[@]} -eq 0 ]]; then
    log_warn "No *.list.chroot files found — nothing to lint."
    exit 0
fi

log_step "Linting ${#ALL_LISTS[@]} package list(s)"

# ---------------------------------------------------------------------------
# Check 1: Naming convention
# ---------------------------------------------------------------------------
log_info "Check 1: Naming convention"

for list_file in "${ALL_LISTS[@]}"; do
    filename="$(basename "${list_file}")"
    if ! [[ "${filename}" =~ ^shopno-os- ]]; then
        _error "Naming violation: '${filename}' must start with 'shopno-os-'"
        _error "  Path: ${list_file}"
    fi
done

# ---------------------------------------------------------------------------
# Check 2: Empty list files
# ---------------------------------------------------------------------------
log_info "Check 2: Empty list files"

for list_file in "${ALL_LISTS[@]}"; do
    # Count non-blank, non-comment lines
    pkg_count=$(grep -cEv '^\s*(#|$)' "${list_file}" 2>/dev/null || true)
    if [[ "${pkg_count}" -eq 0 ]]; then
        _warn "Empty package list (no packages defined): ${list_file}"
    fi
done

# ---------------------------------------------------------------------------
# Check 3: Package name format
# ---------------------------------------------------------------------------
log_info "Check 3: Package name format"

_valid_pkg_name() {
    # Debian package names: lowercase letters, digits, plus, hyphen, dot
    # Must start with alphanumeric
    [[ "${1}" =~ ^[a-z0-9][a-z0-9.+\-]*$ ]]
}

for list_file in "${ALL_LISTS[@]}"; do
    lineno=0
    while IFS= read -r line; do
        (( lineno++ )) || true
        # Skip blanks and comments
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        # Strip inline comments
        pkg="${line%%#*}"
        pkg="${pkg//[[:space:]]/}"
        [[ -z "${pkg}" ]] && continue

        if ! _valid_pkg_name "${pkg}"; then
            _error "Invalid package name at $(basename "${list_file}"):${lineno}: '${pkg}'"
        fi
    done < "${list_file}"
done

# ---------------------------------------------------------------------------
# Check 4: Intra-list duplicates (same package twice in one file)
# ---------------------------------------------------------------------------
log_info "Check 4: Intra-list duplicates"

for list_file in "${ALL_LISTS[@]}"; do
    # Extract package names, find duplicates
    mapfile -t dupes < <(
        grep -Ev '^\s*(#|$)' "${list_file}" 2>/dev/null \
        | awk '{print $1}' \
        | sort \
        | uniq -d
    )
    for dupe in "${dupes[@]}"; do
        [[ -z "${dupe}" ]] && continue
        _warn "Duplicate within same file '$(basename "${list_file}")': '${dupe}'"
    done
done

# ---------------------------------------------------------------------------
# Check 5: Cross-list duplicates (same package in two different lists)
# This is the Golden Rule violation — fatal.
# ---------------------------------------------------------------------------
log_info "Check 5: Cross-list duplicate packages (Golden Rule)"

# Build a master map: package → list files that contain it
declare -A PKG_SOURCES   # pkg → "file1\nfile2"

for list_file in "${ALL_LISTS[@]}"; do
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        pkg="${line%%#*}"
        pkg="${pkg//[[:space:]]/}"
        [[ -z "${pkg}" ]] && continue

        if [[ -n "${PKG_SOURCES[${pkg}]:-}" ]]; then
            PKG_SOURCES["${pkg}"]="${PKG_SOURCES[${pkg}]}
${list_file}"
        else
            PKG_SOURCES["${pkg}"]="${list_file}"
        fi
    done < "${list_file}"
done

CROSS_ERRORS=0
for pkg in "${!PKG_SOURCES[@]}"; do
    mapfile -t sources <<< "${PKG_SOURCES[${pkg}]}"
    if [[ ${#sources[@]} -gt 1 ]]; then
        _error "Golden Rule violation — package '${pkg}' found in multiple lists:"
        for src in "${sources[@]}"; do
            _error "  ${src}"
        done
        (( CROSS_ERRORS++ )) || true
    fi
done

# ---------------------------------------------------------------------------
# Check 6: Wrong-layer packages (policy enforcement)
# ---------------------------------------------------------------------------
log_info "Check 6: Layer policy violations"

# Packages that must NEVER appear in base/
declare -a BASE_FORBIDDEN=(
    xorg xserver-xorg-core gnome-shell kde-plasma-desktop
    xfce4 openbox i3 sway hyprland
    pulseaudio pipewire wireplumber
    gdm3 sddm lightdm
    cups nvidia-driver
)

# Packages that must NEVER appear in flavors/
declare -a FLAVOR_FORBIDDEN=(
    docker.io docker-ce qemu-kvm virt-manager
    build-essential gcc g++ make
    xorg pipewire pulseaudio  # these belong in editions/desktop
)

_check_layer_policy() {
    local layer_path="${1}"
    local layer_label="${2}"
    local -n _forbidden="${3}"

    while IFS= read -r -d '' list_file; do
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            pkg="${line%%#*}"
            pkg="${pkg//[[:space:]]/}"
            [[ -z "${pkg}" ]] && continue

            for forbidden in "${_forbidden[@]}"; do
                if [[ "${pkg}" == "${forbidden}" ]]; then
                    _error "Layer policy violation in ${layer_label}:"
                    _error "  Package '${pkg}' must not live in $(basename "${layer_path}")/"
                    _error "  File: ${list_file}"
                fi
            done
        done < "${list_file}"
    done < <(find "${layer_path}/package-lists" -name "*.list.chroot" -print0 2>/dev/null)
}

BASE_DIR="${OS_REPO_ROOT}/base"
if [[ -d "${BASE_DIR}/package-lists" ]]; then
    _check_layer_policy "${BASE_DIR}" "base" BASE_FORBIDDEN
fi

while IFS= read -r -d '' flavor_dir; do
    _check_layer_policy "${flavor_dir}" "flavors/$(basename "${flavor_dir}")" FLAVOR_FORBIDDEN
done < <(find "${OS_REPO_ROOT}/flavors" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Lint Results"

if [[ "${ERRORS}" -eq 0 && "${WARNINGS}" -eq 0 ]]; then
    log_success "All checks passed — no errors, no warnings."
    exit 0
fi

if [[ "${WARNINGS}" -gt 0 ]]; then
    log_warn "Warnings: ${WARNINGS}"
fi

if [[ "${ERRORS}" -gt 0 ]]; then
    log_error "Errors: ${ERRORS} — build blocked."
    exit 1
fi

# Strict mode: warnings become errors
if [[ "${OPT_STRICT}" -eq 1 && "${WARNINGS}" -gt 0 ]]; then
    log_error "Strict mode: ${WARNINGS} warning(s) treated as errors."
    exit 1
fi

exit 0
