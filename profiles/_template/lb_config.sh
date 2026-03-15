#!/usr/bin/env bash
# =============================================================================
# ShopnoOS — Profile Template: lb_config.sh
# =============================================================================
# Purpose   : Translates profile.env variables into a live-build `lb config`
#             invocation. This script is the single source of truth for how
#             live-build is configured for this profile.
#
# Called by : scripts/build/prepare-lb-config.sh
#             Never call this script directly. Always go through build.sh.
#
# Contract  : This script MUST be called from within the profile's build
#             directory (build/${PROFILE_NAME}/) where lb_config will write
#             its config/ tree.
#
# Assumes   : The following variables are already exported in the environment
#             by the time this script runs (sourced by prepare-lb-config.sh):
#
#   From profile.env (this profile):
#     DISTRO_EDITION, DISTRO_FLAVOR, DISTRO_HARDWARE, DISTRO_ARCH
#     LB_DISTRIBUTION, LB_BINARY_IMAGES, LB_BOOTLOADERS, LB_UEFI_SECURE_BOOT
#     LB_MEMTEST, LB_MIRROR_*, LB_ARCHIVE_AREAS, LB_COMPRESSION
#     LB_HOSTNAME, LB_USERNAME, LB_LOCALE, LB_KEYBOARD_*, LB_TIMEZONE
#     LB_CACHE, LB_COMPRESSION, LB_ISO_VOLUME
#     LB_INITRAMFS_COMPRESSION
#
#   From brand/identity/name.env (loaded by scripts/lib/brand.sh):
#     DISTRO_NAME, DISTRO_CODENAME, DISTRO_VERSION, DISTRO_ID
#     DISTRO_WEBSITE, DISTRO_BUGTRACKER, DISTRO_ID_LIKE
#
#   From scripts/lib/iso-name.sh (loaded by prepare-lb-config.sh):
#     ISO_FILENAME  (the computed ISO output name)
#
#   From vars/defaults.env (global defaults):
#     DEFAULT_ARCH, DEFAULT_DISTRIBUTION, etc.
#
# DO NOT EDIT this script to hard-code profile-specific values.
# All customization belongs in profile.env.
# =============================================================================

set -euo pipefail

# Guard: must be sourced/called by prepare-lb-config.sh, not directly.
if [[ -z "${BUILD_CONTEXT:-}" ]]; then
    echo "ERROR: lb_config.sh must be called via scripts/build/build.sh" >&2
    echo "       Do not run lb_config.sh directly." >&2
    exit 1
fi

# Source the shared library functions (logging, color, error traps).
# shellcheck source=../../scripts/lib/common.sh
source "${LIB_REPO_ROOT}/scripts/lib/common.sh"

log_section "Configuring live-build for profile: ${PROFILE_NAME}"

# =============================================================================
# STEP 1 — RESOLVE EFFECTIVE VALUES
# Merge profile.env values with brand identity and defaults.
# =============================================================================

# Hostname: use profile override, else fall back to DISTRO_ID from brand.
EFFECTIVE_HOSTNAME="${LB_HOSTNAME:-${DISTRO_ID:-shopno}}"

# Live session username: use profile override, else fall back to DISTRO_ID.
EFFECTIVE_USERNAME="${LB_USERNAME:-${DISTRO_ID:-shopno}}"

# ISO Volume label: auto-generate if not overridden in profile.env.
if [[ -z "${LB_ISO_VOLUME:-}" ]]; then
    # Format: "Abrar Linux 1.0 Desktop GNOME"
    # Capitalize edition and flavor for display.
    _edition_cap="$(echo "${DISTRO_EDITION}" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
    if [[ "${DISTRO_FLAVOR}" == "none" ]]; then
        EFFECTIVE_ISO_VOLUME="${DISTRO_NAME} ${DISTRO_VERSION} ${_edition_cap}"
    else
        _flavor_cap="$(echo "${DISTRO_FLAVOR}" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
        EFFECTIVE_ISO_VOLUME="${DISTRO_NAME} ${DISTRO_VERSION} ${_edition_cap} ${_flavor_cap}"
    fi
else
    EFFECTIVE_ISO_VOLUME="${LB_ISO_VOLUME}"
fi

# Truncate to 32 characters (ISO 9660 volume label limit).
EFFECTIVE_ISO_VOLUME="${EFFECTIVE_ISO_VOLUME:0:32}"

log_info "Effective hostname     : ${EFFECTIVE_HOSTNAME}"
log_info "Effective username     : ${EFFECTIVE_USERNAME}"
log_info "Effective ISO volume   : ${EFFECTIVE_ISO_VOLUME}"
log_info "ISO output filename    : ${ISO_FILENAME}"

# =============================================================================
# STEP 2 — BUILD THE lb config ARGUMENT ARRAY
# Each argument group is commented to explain intent.
# Arguments are built into an array to avoid quoting/escaping bugs.
# =============================================================================

LB_CONFIG_ARGS=(

    # -------------------------------------------------------------------------
    # DISTRIBUTION & ARCHITECTURE
    # -------------------------------------------------------------------------
    --distribution          "${LB_DISTRIBUTION}"
    --architectures         "${DISTRO_ARCH}"

    # -------------------------------------------------------------------------
    # MIRROR CONFIGURATION
    # Build-time mirrors (chroot stage) and live-system mirrors (binary stage)
    # are set separately so the built ISO points to the right production mirror.
    # -------------------------------------------------------------------------
    --mirror-bootstrap      "${LB_MIRROR_BOOTSTRAP}"
    --mirror-chroot         "${LB_MIRROR_CHROOT}"
    --mirror-chroot-security "${LB_MIRROR_CHROOT_SECURITY}"
    --mirror-binary         "${LB_MIRROR_BINARY}"
    --mirror-binary-security "${LB_MIRROR_BINARY_SECURITY}"

    # -------------------------------------------------------------------------
    # APT ARCHIVE AREAS
    # Enables contrib, non-free, and non-free-firmware for firmware support.
    # -------------------------------------------------------------------------
    --archive-areas         "${LB_ARCHIVE_AREAS}"

    # -------------------------------------------------------------------------
    # IMAGE FORMAT & BOOTLOADERS
    # -------------------------------------------------------------------------
    --binary-images         "${LB_BINARY_IMAGES}"
    --bootloaders           "${LB_BOOTLOADERS}"

    # -------------------------------------------------------------------------
    # SECURE BOOT
    # Embeds the shim-signed boot chain for UEFI Secure Boot compatibility.
    # Requires shim-signed + grub-efi-amd64-signed in base/package-lists/.
    # -------------------------------------------------------------------------
    --uefi-secure-boot      "${LB_UEFI_SECURE_BOOT}"

    # -------------------------------------------------------------------------
    # MEMTEST
    # -------------------------------------------------------------------------
    --memtest               "${LB_MEMTEST}"

    # -------------------------------------------------------------------------
    # COMPRESSION
    # Squashfs compression (rootfs) and initramfs compression are set separately.
    # -------------------------------------------------------------------------
    --compression           "${LB_COMPRESSION}"
    --initramfs-compression "${LB_INITRAMFS_COMPRESSION}"

    # -------------------------------------------------------------------------
    # FILESYSTEM TYPES
    # -------------------------------------------------------------------------
    --chroot-filesystem     "${LB_CHROOT_FILESYSTEM}"
    --binary-filesystem     "${LB_BINARY_FILESYSTEM}"

    # -------------------------------------------------------------------------
    # CACHE
    # -------------------------------------------------------------------------
    --cache                 "${LB_CACHE}"

    # -------------------------------------------------------------------------
    # LIVE SESSION IDENTITY
    # hostname and username for the live (pre-install) session.
    # -------------------------------------------------------------------------
    --hostname              "${EFFECTIVE_HOSTNAME}"
    --username              "${EFFECTIVE_USERNAME}"

    # -------------------------------------------------------------------------
    # LOCALE & KEYBOARD
    # -------------------------------------------------------------------------
    --language              "${LB_LANGUAGE}"
    --locale                "${LB_LOCALE}"
    --keyboard-layouts      "${LB_KEYBOARD_LAYOUTS}"

    # -------------------------------------------------------------------------
    # ISO METADATA
    # -------------------------------------------------------------------------
    --iso-volume            "${EFFECTIVE_ISO_VOLUME}"
    --iso-publisher         "${DISTRO_NAME} <${DISTRO_WEBSITE}>"
    --iso-application       "${DISTRO_NAME} Live"

    # -------------------------------------------------------------------------
    # DEBIAN INSTALLER
    # "live" = no Debian installer on the ISO (Calamares handles installation).
    # "none" = no installer at all (useful for core/server images).
    # -------------------------------------------------------------------------
    --debian-installer      "none"

    # -------------------------------------------------------------------------
    # LINUX FLAVOUR
    # The kernel flavour to install. "amd64" maps to linux-image-amd64 meta.
    # arm64 profiles should override this to "arm64".
    # -------------------------------------------------------------------------
    --linux-flavours        "${DISTRO_ARCH}"

    # -------------------------------------------------------------------------
    # APT OPTIONS
    # --apt-recommends false  : Do not install Recommends automatically.
    #                           This is CRITICAL for reproducible, controlled
    #                           package lists. Explicit beats implicit.
    #                           If a package is needed, add it to the list.
    # -------------------------------------------------------------------------
    --apt-recommends        "false"

    # -------------------------------------------------------------------------
    # DEBOOTSTRAP OPTIONS
    # Extra options passed to debootstrap for the initial chroot setup.
    # variant=minbase gives the absolute minimum Debian base.
    # -------------------------------------------------------------------------
    --debootstrap-options   "--variant=minbase"

    # -------------------------------------------------------------------------
    # SYSTEM TYPE
    # "live" is the standard for bootable live ISOs.
    # Other options: "normal" (installs only, no live), "rescue"
    # -------------------------------------------------------------------------
    --system                "live"

    # -------------------------------------------------------------------------
    # INITSYSTEM
    # "systemd" is required for modern desktop/server use.
    # -------------------------------------------------------------------------
    --initsystem            "systemd"

    # -------------------------------------------------------------------------
    # UNION FILESYSTEM
    # "overlay" is the modern kernel union filesystem for live sessions.
    # Provides the writable overlay over the squashfs read-only rootfs.
    # -------------------------------------------------------------------------
    --union-filesystem      "overlay"

)

# -------------------------------------------------------------------------
# KEYBOARD VARIANT (optional — only add if non-empty)
# live-build --keyboard-variants does not accept empty strings gracefully.
# -------------------------------------------------------------------------
if [[ -n "${LB_KEYBOARD_VARIANTS:-}" ]]; then
    LB_CONFIG_ARGS+=( --keyboard-variants "${LB_KEYBOARD_VARIANTS}" )
fi

# -------------------------------------------------------------------------
# TIMEZONE (passed as debootstrap include or hook — lb config does not have
# a direct --timezone flag; it is handled by the 0010-locale hook in base/).
# We export it so the hook can pick it up from the environment.
# -------------------------------------------------------------------------
export LB_TIMEZONE

# =============================================================================
# STEP 3 — RUN lb config
# =============================================================================

log_info "Running lb config with ${#LB_CONFIG_ARGS[@]} arguments..."
log_debug "lb config args: ${LB_CONFIG_ARGS[*]}"

lb config "${LB_CONFIG_ARGS[@]}"

log_ok "lb config completed successfully."

# =============================================================================
# STEP 4 — POST-CONFIG VALIDATION
# Sanity-check that the config/ tree was created correctly before continuing.
# This catches lb config silent failures (it exits 0 even on some errors).
# =============================================================================

log_section "Post-config validation"

REQUIRED_LB_DIRS=(
    "config/archives"
    "config/hooks/chroot"
    "config/hooks/binary"
    "config/includes.chroot"
    "config/package-lists"
)

VALIDATION_FAILED=0
for dir in "${REQUIRED_LB_DIRS[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        log_error "Expected directory missing after lb config: ${dir}"
        VALIDATION_FAILED=1
    else
        log_ok "  Found: ${dir}"
    fi
done

if [[ "${VALIDATION_FAILED}" -eq 1 ]]; then
    log_error "lb config validation failed. The config tree is incomplete."
    log_error "Check live-build output above for errors."
    exit 1
fi

# Confirm the package-lists directory has at least one list (injected by
# inject-packages.sh which runs after this script). We only check it's writable.
if [[ ! -w "config/package-lists" ]]; then
    log_error "config/package-lists is not writable. Cannot inject package lists."
    exit 1
fi

log_ok "Post-config validation passed."
log_ok "Profile '${PROFILE_NAME}' is ready for package injection."

# =============================================================================
# STEP 5 — EMIT BUILD STAMP (pre-build metadata)
# Write a machine-readable stamp into the build directory for CI and audit use.
# The full ISO stamp (post-build) is handled by scripts/build/stamp-iso.sh.
# =============================================================================

STAMP_FILE=".shopno-os-profile-stamp"

cat > "${STAMP_FILE}" <<EOF
# ShopnoOS — Pre-Build Profile Stamp
# Generated by: lb_config.sh
# Do not edit — regenerated on every build.
STAMP_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
STAMP_PROFILE="${PROFILE_NAME}"
STAMP_EDITION="${DISTRO_EDITION}"
STAMP_FLAVOR="${DISTRO_FLAVOR}"
STAMP_HARDWARE="${DISTRO_HARDWARE}"
STAMP_ARCH="${DISTRO_ARCH}"
STAMP_DISTRIBUTION="${LB_DISTRIBUTION}"
STAMP_VERSION="${DISTRO_VERSION}"
STAMP_CODENAME="${DISTRO_CODENAME}"
STAMP_ISO_VOLUME="${EFFECTIVE_ISO_VOLUME}"
STAMP_ISO_FILENAME="${ISO_FILENAME}"
STAMP_GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
STAMP_GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
STAMP_BUILD_HOST="$(hostname -f 2>/dev/null || hostname)"
EOF

log_ok "Profile stamp written to: ${STAMP_FILE}"
