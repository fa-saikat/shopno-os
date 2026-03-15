#!/usr/bin/env bash
# =============================================================================
# scripts/lib/profile.sh
# ShopnoOS — Shared Script Library: Build Profile Loader
#
# PURPOSE:
#   Loads and validates a named build profile (profiles/<name>/profile.env),
#   resolves the composition (edition + flavor + hardware), verifies that
#   all referenced layers exist on disk, and exports the final build
#   environment for downstream scripts.
#
# USAGE:
#   source "$(dirname "$0")/../lib/profile.sh"
#   load_profile "shopno-os-desktop-gnome"
#   # DISTRO_EDITION, DISTRO_FLAVOR, LB_* etc. are now available
#
# DEPENDS ON:
#   common.sh + brand.sh (must be sourced first)
#
# GUARDS:
#   Idempotent — safe to source multiple times.
# =============================================================================

[[ -n "${LIB_PROFILE_LOADED:-}" ]] && return 0
readonly LIB_PROFILE_LOADED=1

if [[ -z "${LIB_COMMON_LOADED:-}" ]]; then
    echo "[profile.sh] ERROR: common.sh must be sourced before profile.sh" >&2
    exit 1
fi

# =============================================================================
# KNOWN VALID VALUES
# Add to these arrays when extending the distro.
# =============================================================================

readonly _VALID_EDITIONS=(core desktop pro edu)
readonly _VALID_FLAVORS=(none gnome kde xfce minimal-x)
readonly _VALID_HARDWARE=(generic nvidia amd rpi vm)
readonly _VALID_ARCHES=(amd64 arm64 i386)

# Required vars that every profile.env must define
readonly _PROFILE_REQUIRED_VARS=(
    DISTRO_EDITION
    DISTRO_FLAVOR
    DISTRO_HARDWARE
    DISTRO_ARCH
    LB_DISTRIBUTION
    LB_BINARY_IMAGES
    LB_BOOTLOADERS
)

# =============================================================================
# PUBLIC: load_profile "profile-name"
# =============================================================================

# _ACTIVE_PROFILE_NAME  — set after successful load_profile call
_ACTIVE_PROFILE_NAME=""

# load_profile "name"  — main entry point
# Loads profiles/<name>/profile.env, validates, resolves layers, exports vars.
load_profile() {
    local profile_name="${1:-}"

    if [[ -z "${profile_name}" ]]; then
        log_error "load_profile requires a profile name argument."
        log_error "  Usage: load_profile <profile-name>"
        log_error "  Example: load_profile abrar-desktop-gnome"
        exit 1
    fi

    log_step "Loading profile: ${profile_name}"

    local profile_dir="${LIB_REPO_ROOT}/profiles/${profile_name}"
    local profile_env="${profile_dir}/profile.env"

    require_dir  "${profile_dir}"
    require_file "${profile_env}"

    log_debug "Sourcing: ${profile_env}"
    # shellcheck source=/dev/null
    source "${profile_env}"

    _profile_validate "${profile_name}"
    _profile_resolve_layers
    _profile_export

    _ACTIVE_PROFILE_NAME="${profile_name}"

    log_success "Profile loaded: ${profile_name}"
    log_info "  Edition  : ${DISTRO_EDITION}"
    log_info "  Flavor   : ${DISTRO_FLAVOR}"
    log_info "  Hardware : ${DISTRO_HARDWARE}"
    log_info "  Arch     : ${DISTRO_ARCH}"
    log_info "  Base     : Debian ${LB_DISTRIBUTION}"
    dump_env
}

# =============================================================================
# VALIDATION
# =============================================================================

_profile_validate() {
    local profile_name="${1}"
    local failed=0

    log_debug "Validating profile: ${profile_name}"

    # 1. Required vars present
    for var in "${_PROFILE_REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required profile variable missing: ${var}"
            log_error "  → Check: profiles/${profile_name}/profile.env"
            (( failed++ )) || true
        fi
    done

    [[ "${failed}" -gt 0 ]] && {
        log_error "${failed} required variable(s) missing in profile."
        exit 1
    }

    # 2. Edition is known
    if ! _in_array "${DISTRO_EDITION}" "${_VALID_EDITIONS[@]}"; then
        log_error "Unknown DISTRO_EDITION '${DISTRO_EDITION}' in profile: ${profile_name}"
        log_error "  Valid editions: ${_VALID_EDITIONS[*]}"
        log_error "  To add a new edition: ./scripts/dev/new-edition.sh <name>"
        exit 1
    fi

    # 3. Flavor is known
    if ! _in_array "${DISTRO_FLAVOR}" "${_VALID_FLAVORS[@]}"; then
        log_error "Unknown DISTRO_FLAVOR '${DISTRO_FLAVOR}' in profile: ${profile_name}"
        log_error "  Valid flavors: ${_VALID_FLAVORS[*]}"
        log_error "  To add a new flavor: ./scripts/dev/new-flavor.sh <name>"
        exit 1
    fi

    # 4. Hardware layer is known
    if ! _in_array "${DISTRO_HARDWARE}" "${_VALID_HARDWARE[@]}"; then
        log_error "Unknown DISTRO_HARDWARE '${DISTRO_HARDWARE}' in profile: ${profile_name}"
        log_error "  Valid hardware targets: ${_VALID_HARDWARE[*]}"
        exit 1
    fi

    # 5. Arch is known
    if ! _in_array "${DISTRO_ARCH}" "${_VALID_ARCHES[@]}"; then
        log_error "Unknown DISTRO_ARCH '${DISTRO_ARCH}' in profile: ${profile_name}"
        log_error "  Valid arches: ${_VALID_ARCHES[*]}"
        exit 1
    fi

    # 6. Sanity: core edition must use flavor=none
    if [[ "${DISTRO_EDITION}" == "core" && "${DISTRO_FLAVOR}" != "none" ]]; then
        log_error "The 'core' edition must use DISTRO_FLAVOR=none (got: '${DISTRO_FLAVOR}')."
        log_error "  Core is TTY-only. DE flavors require the 'desktop' or 'pro' edition."
        exit 1
    fi

    # 7. Sanity: flavor=none paired with desktop/pro is suspicious
    if [[ "${DISTRO_FLAVOR}" == "none" && "${DISTRO_EDITION}" =~ ^(desktop|pro)$ ]]; then
        log_warn "DISTRO_FLAVOR=none with edition '${DISTRO_EDITION}' — this will produce a headless image."
        log_warn "  If this is intentional, you can ignore this warning."
    fi

    log_debug "Profile validation passed."
}

# =============================================================================
# LAYER RESOLUTION
# Verifies that the referenced edition / flavor / hardware directories exist
# and contain at least one package list.
# =============================================================================

_profile_resolve_layers() {
    log_debug "Resolving composition layers..."

    local -a layers_to_check=()

    # Base — always present (validated separately by build.sh)
    local base_dir="${LIB_REPO_ROOT}/base"
    require_dir "${base_dir}/package-lists"

    # Edition layer
    local edition_dir="${LIB_REPO_ROOT}/editions/${DISTRO_EDITION}"
    require_dir "${edition_dir}"
    _assert_has_package_lists "${edition_dir}" "edition/${DISTRO_EDITION}"

    # Flavor layer (skip for 'none')
    if [[ "${DISTRO_FLAVOR}" != "none" ]]; then
        local flavor_dir="${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}"
        require_dir "${flavor_dir}"
        _assert_has_package_lists "${flavor_dir}" "flavor/${DISTRO_FLAVOR}"
    fi

    # Hardware layer (skip for 'generic')
    if [[ "${DISTRO_HARDWARE}" != "generic" ]]; then
        local hw_dir="${LIB_REPO_ROOT}/hardware/${DISTRO_HARDWARE}"
        require_dir "${hw_dir}"
        _assert_has_package_lists "${hw_dir}" "hardware/${DISTRO_HARDWARE}"
    fi

    log_debug "All layers resolved successfully."
}

# _assert_has_package_lists "dir" "label"  — fails if no *.list.chroot files found
_assert_has_package_lists() {
    local dir="${1}"
    local label="${2}"
    local count
    count=$(find "${dir}/package-lists" -name "*.list.chroot" 2>/dev/null | wc -l)
    if [[ "${count}" -eq 0 ]]; then
        log_error "Layer '${label}' has no package lists in: ${dir}/package-lists/"
        log_error "  Every layer must contain at least one *.list.chroot file."
        exit 1
    fi
    log_debug "  Layer '${label}': ${count} package list(s) found."
}

# =============================================================================
# EXPORT
# =============================================================================

_profile_export() {
    # Export all DISTRO_* and LB_* vars so child processes and lb_config.sh see them
    while IFS='=' read -r key _; do
        [[ "${key}" =~ ^(DISTRO_|LB_) ]] && export "${key?}"
    done < <(compgen -v | grep -E '^(DISTRO_|LB_)')
}

# =============================================================================
# INTROSPECTION HELPERS (callable after load_profile)
# =============================================================================

# active_profile  — prints the currently loaded profile name
active_profile() {
    if [[ -z "${_ACTIVE_PROFILE_NAME}" ]]; then
        log_error "No profile loaded. Call load_profile first."
        exit 1
    fi
    echo "${_ACTIVE_PROFILE_NAME}"
}

# profile_has_flavor  — returns 0 if flavor is not 'none'
profile_has_flavor() {
    [[ "${DISTRO_FLAVOR:-none}" != "none" ]]
}

# profile_has_hardware_overlay  — returns 0 if hardware is not 'generic'
profile_has_hardware_overlay() {
    [[ "${DISTRO_HARDWARE:-generic}" != "generic" ]]
}

# profile_package_lists  — prints paths to all package lists for active profile,
# in composition order: base → edition → flavor → hardware
profile_package_lists() {
    local base_dir="${LIB_REPO_ROOT}/base"
    local edition_dir="${LIB_REPO_ROOT}/editions/${DISTRO_EDITION}"

    find "${base_dir}/package-lists"    -name "*.list.chroot" | sort
    find "${edition_dir}/package-lists" -name "*.list.chroot" | sort

    if profile_has_flavor; then
        local flavor_dir="${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}"
        find "${flavor_dir}/package-lists" -name "*.list.chroot" | sort
    fi

    if profile_has_hardware_overlay; then
        local hw_dir="${LIB_REPO_ROOT}/hardware/${DISTRO_HARDWARE}"
        find "${hw_dir}/package-lists" -name "*.list.chroot" | sort
    fi
}

# profile_hook_dirs  — prints chroot hook directories in merge order
profile_hook_dirs() {
    local dirs=()
    dirs+=("${LIB_REPO_ROOT}/base/hooks/chroot")
    dirs+=("${LIB_REPO_ROOT}/editions/${DISTRO_EDITION}/hooks/chroot")

    if profile_has_flavor; then
        dirs+=("${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}/hooks/chroot")
    fi
    if profile_has_hardware_overlay; then
        dirs+=("${LIB_REPO_ROOT}/hardware/${DISTRO_HARDWARE}/hooks/chroot")
    fi

    for d in "${dirs[@]}"; do
        [[ -d "${d}" ]] && echo "${d}"
    done
}

# list_profiles  — prints all available profile names
list_profiles() {
    find "${LIB_REPO_ROOT}/profiles" -mindepth 1 -maxdepth 1 -type d \
        ! -name '_template' \
        -exec basename {} \; | sort
}

# =============================================================================
# PRIVATE UTILITIES
# =============================================================================

# _in_array "needle" "elem1" "elem2" ...  — returns 0 if needle is in array
_in_array() {
    local needle="${1}"
    shift
    local elem
    for elem in "$@"; do
        [[ "${elem}" == "${needle}" ]] && return 0
    done
    return 1
}
