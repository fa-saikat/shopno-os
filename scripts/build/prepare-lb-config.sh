#!/usr/bin/env bash
# =============================================================================
# scripts/build/prepare-lb-config.sh
# ShopnoOS — Live-build Config Tree Assembler
#
# USAGE:
#   ./scripts/build/prepare-lb-config.sh <profile-name> <build-dir>
#
# PURPOSE:
#   1. Creates and enters the build/<profile>/ working directory
#   2. Calls the profile's lb_config.sh to run `lb config`
#   3. Merges config overlays in order: base → edition → flavor → hardware
#   4. Injects brand identity into chroot config (os-release hook, hostname, etc.)
#   5. Writes a build-info record for downstream scripts
#
# Config merge order:
#   base/config/        → applied first  (lowest priority)
#   editions/<e>/config → applied second
#   flavors/<f>/config  → applied third
#   hardware/<h>/config → applied last   (highest priority — hardware always wins)
#
# Each layer's config/ subtree is rsync-merged into build/<profile>/config/
# Later layers overwrite earlier ones for the same path.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/brand.sh
source "${LIB_DIR}/brand.sh"
# shellcheck source=../lib/profile.sh
source "${LIB_DIR}/profile.sh"
# shellcheck source=../lib/iso-name.sh
source "${LIB_DIR}/iso-name.sh"

source "${LIB_REPO_ROOT}/brand/identity/name.env"
source "${LIB_REPO_ROOT}/brand/identity/urls.env" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PROFILE_NAME="${1:-}"
BUILD_DIR="${2:-}"

[[ -z "${PROFILE_NAME}" ]] && { log_error "Usage: $0 <profile-name> <build-dir>"; exit 1; }
[[ -z "${BUILD_DIR}"    ]] && { log_error "Usage: $0 <profile-name> <build-dir>"; exit 1; }

# Brand already loaded by sourcing brand.sh above
# Load profile
load_profile "${PROFILE_NAME}"

# ---------------------------------------------------------------------------
# Prepare build directory
# ---------------------------------------------------------------------------
log_step "Preparing build directory: ${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Run lb config via the profile's own lb_config.sh
# ---------------------------------------------------------------------------
log_step "Running lb config for profile: ${PROFILE_NAME}"
PROFILE_LB_CONFIG="${LIB_REPO_ROOT}/profiles/${PROFILE_NAME}/lb_config.sh"
require_file "${PROFILE_LB_CONFIG}"

_run bash "${PROFILE_LB_CONFIG}"
log_success "lb config complete."

# ---------------------------------------------------------------------------
# Merge config overlays: base → edition → flavor → hardware
# ---------------------------------------------------------------------------
log_step "Merging config overlays"

_merge_config_overlay() {
    local src_dir="${1}"
    local label="${2}"
    local config_subdir="${src_dir}/config"

    if [[ ! -d "${config_subdir}" ]]; then
        log_debug "No config overlay for ${label} — skipping."
        return 0
    fi

    log_info "Merging config overlay: ${label}"
    # rsync: later calls overwrite earlier ones for the same destination path
    rsync -a --no-owner --no-group \
        "${config_subdir}/" \
        "${BUILD_DIR}/config/"
    log_debug "  Merged: ${config_subdir} → ${BUILD_DIR}/config/"
}

_merge_config_overlay "${LIB_REPO_ROOT}/base"                           "base"
_merge_config_overlay "${LIB_REPO_ROOT}/editions/${DISTRO_EDITION}"     "edition/${DISTRO_EDITION}"

if profile_has_flavor; then
    _merge_config_overlay "${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}"   "flavor/${DISTRO_FLAVOR}"
fi

if profile_has_hardware_overlay; then
    _merge_config_overlay "${LIB_REPO_ROOT}/hardware/${DISTRO_HARDWARE}" "hardware/${DISTRO_HARDWARE}"
fi

log_success "Config overlays merged."

# ---------------------------------------------------------------------------
# Merge hook directories: base → edition → flavor → hardware
# Hooks are numbered (0010-, 0020-) so ordering across layers is explicit.
# ---------------------------------------------------------------------------
log_step "Merging chroot hooks"

HOOKS_DEST="${BUILD_DIR}/config/hooks/normal" # <-- NOTE
mkdir -p "${HOOKS_DEST}"

_merge_hooks() {
    local hooks_dir="${1}"
    local label="${2}"

    if [[ ! -d "${hooks_dir}" ]]; then
        log_debug "No hooks directory for ${label} — skipping."
        return 0
    fi

    local count=0
    while IFS= read -r -d '' hook_file; do
        local hook_basename
        hook_basename="$(basename "${hook_file}")"
        local dest="${HOOKS_DEST}/${hook_basename}"

        if [[ -e "${dest}" ]]; then
            log_warn "Hook collision: ${hook_basename} already exists (from earlier layer)."
            log_warn "  New source: ${hook_file}"
            log_warn "  Overwriting — ensure hook numbers don't conflict across layers."
        fi

        cp "${hook_file}" "${dest}"
        chmod +x "${dest}"
        (( count++ )) || true
        log_debug "  Hook: ${hook_basename}"
    done < <(find "${hooks_dir}" -maxdepth 1 -name "*.hook.chroot" -print0 | sort -z)

    [[ "${count}" -gt 0 ]] && log_info "  ${label}: ${count} hook(s) merged"
}

_merge_hooks "${LIB_REPO_ROOT}/base/hooks/chroot"                             "base"
_merge_hooks "${LIB_REPO_ROOT}/editions/${DISTRO_EDITION}/hooks/chroot"       "edition/${DISTRO_EDITION}"

if profile_has_flavor; then
    _merge_hooks "${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}/hooks/chroot"     "flavor/${DISTRO_FLAVOR}"
fi

if profile_has_hardware_overlay; then
    _merge_hooks "${LIB_REPO_ROOT}/hardware/${DISTRO_HARDWARE}/hooks/chroot"  "hardware/${DISTRO_HARDWARE}"
fi

log_success "Hooks merged."

# ---------------------------------------------------------------------------
# Merge skel directories (flavor only — base and editions don't have skel)
# ---------------------------------------------------------------------------
if profile_has_flavor; then
    SKEL_SRC="${LIB_REPO_ROOT}/flavors/${DISTRO_FLAVOR}/skel"
    SKEL_DEST="${BUILD_DIR}/config/includes.chroot/etc/skel"

    if [[ -d "${SKEL_SRC}" ]]; then
        log_step "Merging skel: flavor/${DISTRO_FLAVOR}"
        mkdir -p "${SKEL_DEST}"
        rsync -a "${SKEL_SRC}/" "${SKEL_DEST}/"
        log_success "Skel merged."
    fi
fi

# Also merge brand-wide skel
BRAND_SKEL="${LIB_REPO_ROOT}/brand/skel-branding"
if [[ -d "${BRAND_SKEL}" ]]; then
    log_info "Merging brand skel overlay"
    SKEL_DEST="${BUILD_DIR}/config/includes.chroot/etc/skel"
    mkdir -p "${SKEL_DEST}"
    rsync -a "${BRAND_SKEL}/" "${SKEL_DEST}/"
fi

# ---------------------------------------------------------------------------
# Inject brand assets into includes.chroot
# ---------------------------------------------------------------------------
log_step "Injecting brand assets"

INCLUDES_CHROOT="${BUILD_DIR}/config/includes.chroot"
VARS_DEST="${INCLUDES_CHROOT}/etc/${ISO_PREFIX}/build-vars.env"

# Release files vars
cat > "$VARS_DEST" <<EOF
DISTRO_NAME="${DISTRO_NAME}"
DISTRO_CODENAME="${DISTRO_CODENAME}"
DISTRO_VERSION="${DISTRO_VERSION}"
DISTRO_ID="${DISTRO_ID}"
DISTRO_ID_LIKE="${DISTRO_ID_LIKE}"
DISTRO_WEBSITE="${DISTRO_WEBSITE}"
DISTRO_BUGTRACKER="${DISTRO_BUGTRACKER:-}"
EOF

# GRUB background
GRUB_BG="$(brand_grub_background)"
if [[ -f "${GRUB_BG}" ]]; then
    GRUB_THEME_DEST="${INCLUDES_CHROOT}/boot/grub/themes/shopno-os"
    mkdir -p "${GRUB_THEME_DEST}"
    cp "${GRUB_BG}" "${GRUB_THEME_DEST}/background.png"
    log_debug "GRUB background injected."
fi

# Plymouth logo
PLYMOUTH_LOGO="$(brand_plymouth_logo)"
if [[ -f "${PLYMOUTH_LOGO}" ]]; then
    PLYMOUTH_DEST="${INCLUDES_CHROOT}/usr/share/plymouth/themes/shopno-os"
    mkdir -p "${PLYMOUTH_DEST}"
    cp "${PLYMOUTH_LOGO}" "${PLYMOUTH_DEST}/logo.png"
    log_debug "Plymouth logo injected."
fi

# Wallpaper (base)
BASE_WALLPAPER="$(brand_wallpaper_base)"
if [[ -f "${BASE_WALLPAPER}" ]]; then
    WP_DEST="${INCLUDES_CHROOT}/usr/share/backgrounds/shopno-os"
    mkdir -p "${WP_DEST}"
    cp "${BASE_WALLPAPER}" "${WP_DEST}/"
    log_debug "Base wallpaper injected."
fi

log_success "Brand assets injected."

# ---------------------------------------------------------------------------
# Write build-info record
# ---------------------------------------------------------------------------
log_step "Writing build-info record"

BUILD_INFO_FILE="${BUILD_DIR}/build-info.env"
cat > "${BUILD_INFO_FILE}" <<EOF
# ShopnoOS build info — generated by prepare-lb-config.sh
# Do not edit manually.
SHOPNOOS_PROFILE="${PROFILE_NAME}"
SHOPNOOS_BUILD_DIR="${BUILD_DIR}"
SHOPNOOS_ISO_FILENAME="$(iso_name)"
SHOPNOOS_ISO_STEM="$(iso_stem)"
SHOPNOOS_BUILD_DATE="$(iso_build_date)"
SHOPNOOS_DISTRO_EDITION="${DISTRO_EDITION}"
SHOPNOOS_DISTRO_FLAVOR="${DISTRO_FLAVOR}"
SHOPNOOS_DISTRO_HARDWARE="${DISTRO_HARDWARE}"
SHOPNOOS_DISTRO_ARCH="${DISTRO_ARCH}"
SHOPNOOS_LB_DISTRIBUTION="${LB_DISTRIBUTION}"
EOF

log_success "Build info written: ${BUILD_INFO_FILE}"
log_success "prepare-lb-config complete."
