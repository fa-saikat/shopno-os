#!/usr/bin/env bash
# =============================================================================
# scripts/lib/brand.sh
# ShopnoOS — Shared Script Library: Brand Identity Loader
#
# PURPOSE:
#   Single source of truth for all branding variables.
#   Loads brand/identity/*.env files, validates required keys, and
#   exports them into the environment for use by all build scripts and hooks.
#
# USAGE:
#   source "$(dirname "$0")/../lib/brand.sh"
#   # All DISTRO_* vars are now available
#
# DEPENDS ON:
#   common.sh (must be sourced first)
#
# GUARDS:
#   Idempotent — safe to source multiple times.
# =============================================================================

[[ -n "${LIB_BRAND_LOADED:-}" ]] && return 0
readonly LIB_BRAND_LOADED=1

# Ensure common.sh was sourced
if [[ -z "${LIB_COMMON_LOADED:-}" ]]; then
    echo "[brand.sh] ERROR: common.sh must be sourced before brand.sh" >&2
    exit 1
fi

# =============================================================================
# BRAND IDENTITY FILES
# =============================================================================

readonly LIB_BRAND_DIR="${OS_REPO_ROOT}/brand/identity"

_BRAND_ENV_FILES=(
    "${LIB_BRAND_DIR}/name.env"
    "${LIB_BRAND_DIR}/colors.env"
    "${LIB_BRAND_DIR}/urls.env"
)

# =============================================================================
# LOADER
# =============================================================================

# _load_brand_file "path"  — source a single .env file with validation
_load_brand_file() {
    local env_file="${1}"

    if [[ ! -f "${env_file}" ]]; then
        log_warn "Brand file not found (skipping): ${env_file}"
        return 0
    fi

    log_debug "Loading brand file: ${env_file}"

    # Validate: only KEY=value lines, comments (#), and blank lines allowed
    local line_no=0
    while IFS= read -r line; do
        (( line_no++ )) || true
        # skip blanks and comments
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        # must match KEY=value (KEY: uppercase, digits, underscores)
        if ! [[ "${line}" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            log_error "Invalid line in ${env_file}:${line_no}: ${line}"
            log_error "Brand .env files must contain only KEY=value pairs, comments, or blank lines."
            exit 1
        fi
    done < "${env_file}"

    # Source it — all vars become available
    # shellcheck source=/dev/null
    source "${env_file}"
}

# load_brand  — load all brand identity files and export everything
load_brand() {
    log_step "Loading brand identity"

    require_dir "${LIB_BRAND_DIR}"

    for env_file in "${_BRAND_ENV_FILES[@]}"; do
        _load_brand_file "${env_file}"
    done

    # Validate required identity vars
    _brand_validate

    # Export all DISTRO_* and BRAND_* vars so child processes inherit them
    while IFS='=' read -r key _; do
        [[ "${key}" =~ ^(DISTRO_|BRAND_) ]] && export "${key?}"
    done < <(compgen -v | grep -E '^(DISTRO_|BRAND_)')

    log_success "Brand identity loaded: ${DISTRO_NAME} ${DISTRO_VERSION} (${DISTRO_CODENAME})"
    dump_env
}

# =============================================================================
# VALIDATION
# =============================================================================

# Required vars that MUST be present in brand/identity/name.env
readonly _BRAND_REQUIRED_NAME_VARS=(
    DISTRO_NAME
    DISTRO_CODENAME
    DISTRO_VERSION
    DISTRO_ID
    DISTRO_ID_LIKE
    DISTRO_WEBSITE
    DISTRO_BUGTRACKER
)

_brand_validate() {
    log_debug "Validating required brand variables..."
    local failed=0

    for var in "${_BRAND_REQUIRED_NAME_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required brand variable is unset or empty: ${var}"
            log_error "  → Check: ${LIB_BRAND_DIR}/name.env"
            (( failed++ )) || true
        fi
    done

    if [[ "${failed}" -gt 0 ]]; then
        log_error "${failed} required brand variable(s) missing — cannot continue."
        exit 1
    fi

    # Version must be semver-like: digits and dots only (e.g. 1.0, 1.0.1, 2024.01)
    if ! [[ "${DISTRO_VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        log_error "DISTRO_VERSION '${DISTRO_VERSION}' is not a valid version string."
        log_error "  Expected format: 1.0 or 1.0.1 or 2024.01"
        exit 1
    fi

    # DISTRO_ID must be lowercase, no spaces (used in filenames and ISO names)
    if ! [[ "${DISTRO_ID}" =~ ^[a-z][a-z0-9\-]*$ ]]; then
        log_error "DISTRO_ID '${DISTRO_ID}' must be lowercase alphanumeric with optional hyphens."
        log_error "  It is used in filenames and ISO names — no spaces or uppercase."
        exit 1
    fi

    log_debug "Brand validation passed."
}

# =============================================================================
# BRAND ASSET HELPERS
# =============================================================================

# brand_logo_svg  — prints the path to the primary SVG logo
brand_logo_svg() {
    echo "${OS_REPO_ROOT}/brand/assets/logo/logo.svg"
}

# brand_wallpaper_base [variant]  — prints path to a base wallpaper
# variant defaults to "shopno-os-default"
brand_wallpaper_base() {
    local variant="${1:-shopno-os-default}"
    echo "${OS_REPO_ROOT}/brand/assets/wallpapers/base/${variant}.png"
}

# brand_wallpaper_edition "edition"  — prints path to edition wallpaper dir
brand_wallpaper_edition() {
    local edition="${1}"
    require_var edition
    echo "${OS_REPO_ROOT}/brand/assets/wallpapers/editions/${edition}"
}

# brand_grub_background  — path to GRUB background image
brand_grub_background() {
    echo "${OS_REPO_ROOT}/brand/assets/grub/background.png"
}

# brand_plymouth_logo  — path to Plymouth logo
brand_plymouth_logo() {
    echo "${OS_REPO_ROOT}/brand/assets/plymouth/logo.png"
}

# =============================================================================
# OS-RELEASE GENERATOR
# Called by hooks to write /etc/os-release into the chroot.
# Uses sourced brand vars — never reads files from inside chroot.
# =============================================================================

# generate_os_release "output_path"
# Writes a standards-compliant /etc/os-release file.
generate_os_release() {
    local output_path="${1:-/etc/os-release}"

    # DISTRO_* vars must already be loaded
    require_var DISTRO_NAME DISTRO_VERSION DISTRO_CODENAME DISTRO_ID DISTRO_ID_LIKE \
                DISTRO_WEBSITE DISTRO_BUGTRACKER

    # Build date for BUILD_ID
    local build_date
    build_date="$(shopno-os_build_date)"

    cat > "${output_path}" <<EOF
# Generated by ShopnoOS build system — do not edit manually
NAME="${DISTRO_NAME}"
VERSION="${DISTRO_VERSION} (${DISTRO_CODENAME})"
VERSION_ID="${DISTRO_VERSION}"
VERSION_CODENAME="${DISTRO_CODENAME,,}"
ID="${DISTRO_ID}"
ID_LIKE="${DISTRO_ID_LIKE}"
PRETTY_NAME="${DISTRO_NAME} ${DISTRO_VERSION} (${DISTRO_CODENAME})"
ANSI_COLOR="1;34"
HOME_URL="${DISTRO_WEBSITE}"
BUG_REPORT_URL="${DISTRO_BUGTRACKER}"
BUILD_ID="${DISTRO_ID}-${DISTRO_VERSION}-${build_date}"
EOF

    log_debug "os-release written to: ${output_path}"
}

# =============================================================================
# AUTO-LOAD on source
# =============================================================================
load_brand
