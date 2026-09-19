#!/usr/bin/env bash
# =============================================================================
# scripts/dev/new-profile.sh
# ShopnoOS - New Build Profile Scaffolder
#
# USAGE:
#   ./scripts/dev/new-profile.sh <profile-name> [--edition E] [--flavor F] [--hardware H]
#
# EXAMPLES:
#   ./scripts/dev/new-profile.sh shopno-os-desktop-hyprland --edition desktop --flavor hyprland
#   ./scripts/dev/new-profile.sh shopno-os-pro-kde-nvidia   --edition pro --flavor kde --hardware nvidia
#   ./scripts/dev/new-profile.sh shopno-os-edu-xfce         --edition edu --flavor xfce
#
# If --edition/--flavor/--hardware are not provided, they are inferred
# from the profile name using the naming convention:
#   shopno-os-<edition>-<flavor>[-<hardware>]
#
# WHAT IT CREATES:
#   profiles/<name>/
#   ├── profile.env    (complete, ready to use)
#   └── lb_config.sh   (complete, ready to use)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/brand.sh
source "${LIB_DIR}/brand.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PROFILE_NAME=""
OPT_EDITION=""
OPT_FLAVOR=""
OPT_HARDWARE="generic"
OPT_ARCH="amd64"

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <profile-name> [options]

Options:
  --edition   E   Edition name (inferred from profile name if omitted)
  --flavor    F   Flavor name  (inferred from profile name if omitted)
  --hardware  H   Hardware layer (default: generic)
  --arch      A   Architecture (default: amd64)
  -h, --help      Show this help

Examples:
  $0 shopno-os-desktop-gnome
  $0 shopno-os-pro-kde-nvidia --hardware nvidia
  $0 shopno-os-core
EOF
    exit 1
}

[[ $# -eq 0 ]] && _usage

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --edition)   OPT_EDITION="${2}";  shift ;;
        --flavor)    OPT_FLAVOR="${2}";   shift ;;
        --hardware)  OPT_HARDWARE="${2}"; shift ;;
        --arch)      OPT_ARCH="${2}";     shift ;;
        -h|--help)   _usage ;;
        -*)          log_error "Unknown option: ${1}"; _usage ;;
        *)
            [[ -n "${PROFILE_NAME}" ]] && { log_error "Multiple profile names."; _usage; }
            PROFILE_NAME="${1}"
            ;;
    esac
    shift
done

[[ -z "${PROFILE_NAME}" ]] && { log_error "Profile name required."; _usage; }

# ---------------------------------------------------------------------------
# Infer edition/flavor from profile name if not explicitly set
# Convention: shopno-os-<edition>-<flavor>[-<hardware>]
# ---------------------------------------------------------------------------
_infer_from_name() {
    # Strip 'shopno-os-' prefix
    local remainder="${PROFILE_NAME#shopno-os-}"
    # Split by '-'
    IFS='-' read -ra parts <<< "${remainder}"

    if [[ -z "${OPT_EDITION}" ]]; then
        OPT_EDITION="${parts[0]:-core}"
        log_info "Inferred edition from profile name: ${OPT_EDITION}"
    fi

    if [[ -z "${OPT_FLAVOR}" ]]; then
        if [[ ${#parts[@]} -ge 2 ]]; then
            OPT_FLAVOR="${parts[1]}"
        else
            OPT_FLAVOR="none"
        fi
        # If flavor matches a known hardware layer and hardware not set, treat as hardware
        known_hw=(nvidia amd rpi vm)
        for hw in "${known_hw[@]}"; do
            if [[ "${OPT_FLAVOR}" == "${hw}" && "${OPT_HARDWARE}" == "generic" ]]; then
                log_warn "Flavor '${OPT_FLAVOR}' looks like a hardware layer - treating as hardware."
                OPT_HARDWARE="${OPT_FLAVOR}"
                OPT_FLAVOR="none"
            fi
        done
        log_info "Inferred flavor from profile name: ${OPT_FLAVOR}"
    fi

    # Third component = hardware override
    if [[ ${#parts[@]} -ge 3 && "${OPT_HARDWARE}" == "generic" ]]; then
        OPT_HARDWARE="${parts[2]}"
        log_info "Inferred hardware from profile name: ${OPT_HARDWARE}"
    fi
}

_infer_from_name

# Normalize 'none'
[[ -z "${OPT_FLAVOR}" ]] && OPT_FLAVOR="none"

log_info "Profile : ${PROFILE_NAME}"
log_info "Edition : ${OPT_EDITION}"
log_info "Flavor  : ${OPT_FLAVOR}"
log_info "Hardware: ${OPT_HARDWARE}"
log_info "Arch    : ${OPT_ARCH}"

# ---------------------------------------------------------------------------
# Validate that referenced layers exist
# ---------------------------------------------------------------------------
require_dir "${OS_REPO_ROOT}/editions/${OPT_EDITION}" \
    || { log_error "Edition '${OPT_EDITION}' not found. Create it first with new-edition.sh"; exit 1; }

if [[ "${OPT_FLAVOR}" != "none" ]]; then
    [[ -d "${OS_REPO_ROOT}/flavors/${OPT_FLAVOR}" ]] \
        || { log_error "Flavor '${OPT_FLAVOR}' not found. Create it first with new-flavor.sh"; exit 1; }
fi

if [[ "${OPT_HARDWARE}" != "generic" ]]; then
    [[ -d "${OS_REPO_ROOT}/hardware/${OPT_HARDWARE}" ]] \
        || { log_error "Hardware layer '${OPT_HARDWARE}' not found."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Create profile directory
# ---------------------------------------------------------------------------
PROFILE_DIR="${OS_REPO_ROOT}/profiles/${PROFILE_NAME}"

if [[ -d "${PROFILE_DIR}" ]]; then
    log_error "Profile already exists: ${PROFILE_DIR}"
    exit 1
fi

mkdir -p "${PROFILE_DIR}"
log_step "Creating profile: ${PROFILE_NAME}"

# ---------------------------------------------------------------------------
# Write profile.env
# ---------------------------------------------------------------------------
cat > "${PROFILE_DIR}/profile.env" <<EOF
# =============================================================================
# ShopnoOS - Build Profile: ${PROFILE_NAME}
# =============================================================================
# Composition: base + ${OPT_EDITION} edition + ${OPT_FLAVOR} flavor + ${OPT_HARDWARE} hardware
# Generated by: ./scripts/dev/new-profile.sh
# =============================================================================

DISTRO_EDITION="${OPT_EDITION}"
DISTRO_FLAVOR="${OPT_FLAVOR}"
DISTRO_HARDWARE="${OPT_HARDWARE}"
DISTRO_ARCH="${OPT_ARCH}"

# Debian base
LB_DISTRIBUTION="${BASE_DISTRIBUTION}"
LB_PARENT_DISTRIBUTION="${BASE_DISTRIBUTION}"
LB_PARENT_MIRROR_BOOTSTRAP="http://deb.debian.org/debian/"
LB_PARENT_MIRROR_CHROOT="http://deb.debian.org/debian/"
LB_PARENT_MIRROR_BINARY="http://deb.debian.org/debian/"
LB_PARENT_MIRROR_CHROOT_SECURITY="http://security.debian.org/debian-security/"
LB_PARENT_MIRROR_BINARY_SECURITY="http://security.debian.org/debian-security/"

# Image type
LB_BINARY_IMAGES="iso-hybrid"
LB_BOOTLOADERS="grub-efi grub-pc"
LB_UEFI_SECURE_BOOT="auto"

# Boot (console=ttyS0,115200n8 required for QEMU serial boot gate - see tests/smoke/test-iso-boots.sh)
LB_MEMTEST="none"
LB_BOOTAPPEND_LIVE="boot=live components quiet splash console=ttyS0,115200n8"
LB_BOOTAPPEND_INSTALL=""

# Build options
LB_CACHE="true"
LB_CACHE_PACKAGES="true"
LB_CACHE_STAGES="bootstrap"
LB_COMPRESSION="xz"
LB_DEBCONF_PRIORITY="critical"
LB_HOSTNAME="shopno-os"
LB_USERNAME="user"
LB_INITRAMFS="live-boot"
LB_INITRAMFS_COMPRESSION="xz"

# Locale
LB_LANGUAGE="en"
LB_COUNTRY="US"
LB_KEYBOARD_LAYOUTS="us"
LB_TIMEZONE="UTC"

# No recommends bloat
LB_APT_RECOMMENDS="false"
LB_APT_SECURE="true"

# Architecture
LB_ARCHITECTURES="${OPT_ARCH}"
LB_LINUX_PACKAGES="linux-image-${OPT_ARCH} linux-headers-${OPT_ARCH}"
LB_LINUX_FLAVOURS="${OPT_ARCH}"
EOF

log_info "Created: profile.env"

# ---------------------------------------------------------------------------
# Write lb_config.sh (copy from template, update header)
# ---------------------------------------------------------------------------
TEMPLATE_LB_CONFIG="${OS_REPO_ROOT}/profiles/_template/lb_config.sh"

if [[ -f "${TEMPLATE_LB_CONFIG}" ]]; then
    cp "${TEMPLATE_LB_CONFIG}" "${PROFILE_DIR}/lb_config.sh"
    # Update the profile name comment in the copy
    sed -i "s|_template|${PROFILE_NAME}|g" "${PROFILE_DIR}/lb_config.sh"
else
    # Generate lb_config.sh from the existing shopno-os-core one as reference
    REFERENCE="${OS_REPO_ROOT}/profiles/shopno-os-core/lb_config.sh"
    if [[ -f "${REFERENCE}" ]]; then
        cp "${REFERENCE}" "${PROFILE_DIR}/lb_config.sh"
        sed -i "s|shopno-os-core|${PROFILE_NAME}|g" "${PROFILE_DIR}/lb_config.sh"
    else
        log_warn "No template lb_config.sh found - writing minimal stub."
        cat > "${PROFILE_DIR}/lb_config.sh" <<'LBEOF'
#!/usr/bin/env bash
# Auto-generated lb_config.sh stub - see profiles/shopno-os-core/lb_config.sh for full example
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/brand.sh"
source "${SCRIPT_DIR}/../../scripts/lib/iso-name.sh"
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${PROFILE_DIR}/profile.env"
ISO_FILENAME="$(iso_name)"
lb config noauto \
    --distribution          "${LB_DISTRIBUTION}" \
    --binary-images         "${LB_BINARY_IMAGES}" \
    --bootloaders           "${LB_BOOTLOADERS}" \
    --architectures         "${LB_ARCHITECTURES}" \
    --compression           "${LB_COMPRESSION}" \
    --apt-recommends        "${LB_APT_RECOMMENDS}" \
    --image-name            "${ISO_FILENAME%.iso}" \
    "${@}"
LBEOF
    fi
fi

chmod +x "${PROFILE_DIR}/lb_config.sh"
log_info "Created: lb_config.sh"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_success "Profile '${PROFILE_NAME}' created at: ${PROFILE_DIR}"

# Predict ISO filename (needs vars loaded)
source "${PROFILE_DIR}/profile.env"
BUILD_DATE="$(iso_build_date)"
PREDICTED_ISO="${DISTRO_ID:-shopno}-${DISTRO_VERSION:-1.0}-${OPT_EDITION}-${OPT_FLAVOR}-${OPT_ARCH}-${BUILD_DATE}.iso"
[[ "${OPT_HARDWARE}" != "generic" ]] && PREDICTED_ISO="${PREDICTED_ISO%.iso}-${OPT_HARDWARE}.iso"

echo ""
echo -e "${CLR_BOLD}Predicted ISO name:${CLR_RESET} ${PREDICTED_ISO}"
echo ""
echo -e "${CLR_BOLD}Next steps:${CLR_RESET}"
echo "  1. Review and adjust profiles/${PROFILE_NAME}/profile.env"
echo "  2. Build:  ./scripts/build/build.sh ${PROFILE_NAME}"
echo "  3. Lint:   ./scripts/dev/lint-packages.sh --profile ${PROFILE_NAME}"
