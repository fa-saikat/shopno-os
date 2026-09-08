#!/usr/bin/env bash
# =============================================================================
# scripts/lib/iso-name.sh
# ShopnoOS - Shared Script Library: ISO Naming Law
#
# PURPOSE:
#   Single authoritative source for ISO filename generation.
#   Every ISO name is derived deterministically from build variables.
#   No human guessing. No manual renaming. No exceptions.
#
# NAMING FORMAT:
#   <DISTRO_ID>-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<BUILDDATE>[-<HARDWARE>].iso
#
# EXAMPLES:
#   shopno-os-1.0-core-none-amd64-20250301.iso
#   shopno-os-1.0-desktop-gnome-amd64-20250301.iso
#   shopno-os-1.0-pro-kde-amd64-20250301-nvidia.iso
#
# USAGE:
#   source "$(dirname "$0")/../lib/iso-name.sh"
#   ISO_FILENAME="$(iso_name)"                  # full filename with .iso
#   ISO_STEM="$(iso_stem)"                      # filename without .iso
#   ISO_LABEL="$(iso_volume_label)"             # truncated for FAT32 (≤11 chars)
#
# DEPENDS ON:
#   common.sh + brand.sh + profile.sh (must be sourced first, vars exported)
#
# GUARDS:
#   Idempotent - safe to source multiple times.
# =============================================================================

[[ -n "${LIB_ISO_NAME_LOADED:-}" ]] && return 0
readonly LIB_ISO_NAME_LOADED=1

if [[ -z "${LIB_COMMON_LOADED:-}" ]]; then
    echo "[iso-name.sh] ERROR: common.sh must be sourced before iso-name.sh" >&2
    exit 1
fi

# =============================================================================
# CORE NAMING FUNCTION
# =============================================================================

# iso_name  - prints full ISO filename (with .iso extension)
iso_name() {
    echo "$(iso_stem).iso"
}

# iso_stem  - prints ISO name without extension (used for lb --image-name)
iso_stem() {
    local stem
    stem="$(_build_iso_stem)"
    echo "${stem}"
}

# iso_volume_label  - prints a FAT32-compatible volume label (≤11 chars, uppercase)
# Used for the ISO filesystem label visible when the USB is inserted.
iso_volume_label() {
    local label
    # Take DISTRO_ID + first chars of edition, uppercase, max 11 chars
    label="${DISTRO_ID^^}-${DISTRO_EDITION^^}"
    # Truncate to 11 characters (FAT32 limit)
    echo "${label:0:11}"
}

# iso_checksum_filename  - prints the expected checksum filename
# Follows the same stem as the ISO for easy association.
iso_checksum_filename() {
    local algo="${1:-sha256}"
    echo "$(iso_stem).${algo}"
}

# iso_signature_filename  - prints the GPG signature filename
iso_signature_filename() {
    echo "$(iso_name).gpg"
}

# =============================================================================
# INTERNAL STEM BUILDER
# =============================================================================

# _build_iso_stem  - assembles and validates all components
# _build_iso_stem() {
#     # Ensure required vars are present (brand + profile must be loaded first)
#     require_var \
#         DISTRO_ID \
#         DISTRO_VERSION \
#         DISTRO_EDITION \
#         DISTRO_FLAVOR \
#         DISTRO_ARCH
#
#     local id version edition flavor arch builddate hardware stem
#
#     id="$(_iso_sanitize       "${DISTRO_ID}")"
#     version="$(_iso_sanitize  "${DISTRO_VERSION}")"
#     edition="$(_iso_sanitize  "${DISTRO_EDITION}")"
#     flavor="$(_iso_sanitize   "${DISTRO_FLAVOR}")"
#     arch="$(_iso_sanitize     "${DISTRO_ARCH}")"
#     builddate="$(_iso_builddate)"
#
#     # Validate individual components before composing
#     _iso_validate_component "DISTRO_ID"      "${id}"
#     _iso_validate_component "DISTRO_VERSION" "${version}"
#     _iso_validate_component "DISTRO_EDITION" "${edition}"
#     _iso_validate_component "DISTRO_FLAVOR"  "${flavor}"
#     _iso_validate_component "DISTRO_ARCH"    "${arch}"
#
#     # Core components
#     stem="${id}-${version}-${edition}-${flavor}-${arch}-${builddate}"
#
#     # Hardware suffix - only appended when not 'generic'
#     hardware="${DISTRO_HARDWARE:-generic}"
#     if [[ "${hardware}" != "generic" ]]; then
#         hardware="$(_iso_sanitize "${hardware}")"
#         _iso_validate_component "DISTRO_HARDWARE" "${hardware}"
#         stem="${stem}-${hardware}"
#     fi
#
#     echo "${stem}"
# }

# NOTE
_build_iso_stem() {
    # Ensure required vars are present (brand + profile must be loaded first)
    require_var \
        DISTRO_ID \
        DISTRO_VERSION \
        DISTRO_EDITION \
        DISTRO_FLAVOR \
        DISTRO_ARCH \
        ISO_PREFIX

    local id version edition flavor arch builddate hardware stem

    id="$(_iso_sanitize       "${DISTRO_ID}")"
    version="$(_iso_sanitize  "${DISTRO_VERSION}")"
    edition="$(_iso_sanitize  "${DISTRO_EDITION}")"
    flavor="$(_iso_sanitize   "${DISTRO_FLAVOR}")"
    arch="$(_iso_sanitize     "${DISTRO_ARCH}")"
    builddate="$(_iso_builddate)"
    isoprefix="$(_iso_sanitize "${ISO_PREFIX}")"

    # Validate individual components before composing
    _iso_validate_component "DISTRO_ID"      "${id}"
    _iso_validate_component "DISTRO_VERSION" "${version}"
    _iso_validate_component "DISTRO_EDITION" "${edition}"
    _iso_validate_component "DISTRO_FLAVOR"  "${flavor}"
    _iso_validate_component "DISTRO_ARCH"    "${arch}"
    _iso_validate_component "ISO_PREFIX"     "${isoprefix}"

    # Core components
    stem="${isoprefix}-${version}-${edition}-${flavor}-${arch}-${builddate}"

    # Hardware suffix - only appended when not 'generic'
    hardware="${DISTRO_HARDWARE:-generic}"
    if [[ "${hardware}" != "generic" ]]; then
        hardware="$(_iso_sanitize "${hardware}")"
        _iso_validate_component "DISTRO_HARDWARE" "${hardware}"
        stem="${stem}-${hardware}"
    fi

    echo "${stem}"
}

# =============================================================================
# COMPONENT SANITISATION AND VALIDATION
# =============================================================================

# _iso_sanitize "value"  - lowercase, trim whitespace, replace spaces with hyphens
_iso_sanitize() {
    local val="${1}"
    # lowercase, trim leading/trailing whitespace, replace inner whitespace with -
    val="${val,,}"
    val="${val//[[:space:]]/-}"
    # strip any characters that are not alphanumeric, dot, or hyphen
    val="${val//[^a-z0-9.\-]/}"
    echo "${val}"
}

# _iso_validate_component "name" "value"
# Validates that a sanitised component is non-empty and safe for filenames.
_iso_validate_component() {
    local name="${1}"
    local value="${2}"

    if [[ -z "${value}" ]]; then
        log_error "ISO name component '${name}' is empty after sanitisation."
        log_error "  Raw value: '${!name:-<unset>}'"
        log_error "  Check that ${name} is set to a non-empty, filesystem-safe value."
        exit 1
    fi

    # Must contain only a-z, 0-9, hyphens, or dots
    if ! [[ "${value}" =~ ^[a-z0-9][a-z0-9.\-]*$ ]]; then
        log_error "ISO name component '${name}' contains invalid characters: '${value}'"
        log_error "  Allowed: lowercase letters, digits, hyphens, dots."
        exit 1
    fi

    # Must not start or end with a hyphen or dot (would look like hidden file / flag)
    if [[ "${value}" =~ ^[-.]  || "${value}" =~ [-.]$ ]]; then
        log_error "ISO name component '${name}' must not start or end with '-' or '.': '${value}'"
        exit 1
    fi

    log_debug "  ISO component [${name}]: '${value}' ✓"
}

# =============================================================================
# BUILD DATE
# =============================================================================

# _iso_builddate  - returns YYYYMMDD
# Respects SOURCE_DATE_EPOCH for reproducible builds (set in CI).
_iso_builddate() {
    if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
        # Reproducible build: use the fixed epoch
        date -u -d "@${SOURCE_DATE_EPOCH}" "+%Y%m%d" 2>/dev/null \
            || date -u -r "${SOURCE_DATE_EPOCH}" "+%Y%m%d"  # macOS fallback
    else
        date -u "+%Y%m%d"
    fi
}

# =============================================================================
# METADATA RECORD
# Structured metadata for embedding into ISO and release manifests.
# =============================================================================

# iso_metadata_json  - prints a JSON object with all ISO metadata
# Requires: jq in PATH
iso_metadata_json() {
    require_command jq

    jq -n \
        --arg name         "${DISTRO_NAME:-}" \
        --arg id           "${DISTRO_ID:-}" \
        --arg version      "${DISTRO_VERSION:-}" \
        --arg codename     "${DISTRO_CODENAME:-}" \
        --arg edition      "${DISTRO_EDITION:-}" \
        --arg flavor       "${DISTRO_FLAVOR:-}" \
        --arg hardware     "${DISTRO_HARDWARE:-}" \
        --arg arch         "${DISTRO_ARCH:-}" \
        --arg builddate    "$(_iso_builddate)" \
        --arg filename     "$(iso_name)" \
        --arg label        "$(iso_volume_label)" \
        --arg distribution "${LB_DISTRIBUTION:-}" \
        '{
            distro: {
                name:         $name,
                id:           $id,
                version:      $version,
                codename:     $codename
            },
            build: {
                edition:      $edition,
                flavor:       $flavor,
                hardware:     $hardware,
                arch:         $arch,
                date:         $builddate,
                distribution: $distribution
            },
            output: {
                filename:     $filename,
                volume_label: $label
            }
        }'
}

# iso_metadata_env  - prints a simple KEY=value file (for embedding into ISO)
iso_metadata_env() {
    cat <<EOF
LIB_ISO_NAME="${DISTRO_NAME:-}"
LIB_ISO_ID="${DISTRO_ID:-}"
LIB_ISO_VERSION="${DISTRO_VERSION:-}"
LIB_ISO_CODENAME="${DISTRO_CODENAME:-}"
LIB_ISO_EDITION="${DISTRO_EDITION:-}"
LIB_ISO_FLAVOR="${DISTRO_FLAVOR:-}"
LIB_ISO_HARDWARE="${DISTRO_HARDWARE:-}"
LIB_ISO_ARCH="${DISTRO_ARCH:-}"
LIB_ISO_BUILD_DATE="$(_iso_builddate)"
LIB_ISO_FILENAME="$(iso_name)"
LIB_ISO_DISTRIBUTION="${LB_DISTRIBUTION:-}"
EOF
}

# =============================================================================
# SELF-TEST
# Run with: LIB_ISO_NAME_SELFTEST=1 source iso-name.sh
# =============================================================================

if [[ "${LIB_ISO_NAME_SELFTEST:-0}" == "1" ]]; then
    echo "=== iso-name.sh self-test ==="

    # Minimal stub vars for testing
    DISTRO_ID="shopno"
    DISTRO_NAME="ShopnoOS"
    DISTRO_VERSION="2.0"
    DISTRO_CODENAME="boipoka"
    DISTRO_EDITION="desktop"
    DISTRO_FLAVOR="gnome"
    DISTRO_HARDWARE="generic"
    DISTRO_ARCH="amd64"
    LB_DISTRIBUTION="trixie"

    echo "iso_stem:          $(iso_stem)"
    echo "iso_name:          $(iso_name)"
    echo "iso_volume_label:  $(iso_volume_label)"
    echo "iso_checksum_file: $(iso_checksum_filename sha256)"
    echo "iso_signature:     $(iso_signature_filename)"

    # With hardware suffix
    DISTRO_HARDWARE="nvidia"
    echo ""
    echo "With hardware=nvidia:"
    echo "iso_name: $(iso_name)"

    # Test reproducible build date
    export SOURCE_DATE_EPOCH=1740787200   # 2025-03-01 00:00:00 UTC
    DISTRO_HARDWARE="generic"
    echo ""
    echo "With SOURCE_DATE_EPOCH=1740787200 (2025-03-01):"
    echo "iso_name: $(iso_name)"

    echo "=== self-test complete ==="
fi
