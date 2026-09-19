#!/usr/bin/env bash
# =============================================================================
# ShopnoOS — live-build config assembler for: shopno-os-gaming-xfce
# Called by: scripts/build/prepare-lb-config.sh
# Do NOT run this directly — use: ./scripts/build/build.sh shopno-os-gaming-xfce
# =============================================================================
set -euo pipefail

# --- Source shared libs (must be sourced before this script runs) -----------
# shellcheck source=../../scripts/lib/common.sh
source "$(dirname "$0")/../../scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/brand.sh
source "$(dirname "$0")/../../scripts/lib/brand.sh"
# shellcheck source=../../scripts/lib/profile.sh
source "$(dirname "$0")/../../scripts/lib/profile.sh"
# shellcheck source=../../scripts/lib/iso-name.sh
source "$(dirname "$0")/../../scripts/lib/iso-name.sh"

# --- Load this profile -------------------------------------------------------
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${PROFILE_DIR}/profile.env"

# --- Derive ISO name (Naming Law) -------------------------------------------
ISO_FILENAME="$(iso_name)"          # e.g. shopno-os-1.0-core-none-amd64-20250301.iso
log_info "ISO will be named: ${ISO_FILENAME}"

# --- Assemble live-build config ----------------------------------------------
# lb config noauto \
#     --distribution          "${LB_DISTRIBUTION}" \
#     --parent-distribution   "${LB_PARENT_DISTRIBUTION}" \
#     --mirror-bootstrap      "${LB_PARENT_MIRROR_BOOTSTRAP}" \
#     \
#     --binary-images         "${LB_BINARY_IMAGES}" \
#     \
#     --bootappend-live       "${LB_BOOTAPPEND_LIVE}" \
#     --memtest               "${LB_MEMTEST}" \
#     \
#     --apt-recommends        "${LB_APT_RECOMMENDS}" \
#     --apt-secure            "${LB_APT_SECURE}" \
#     --archive-areas         "${LB_APT_ARCHIVE_AREAS}" \
#     --apt-source-archives   "${LB_APT_SOURCE_ARCHIVES}" \
#     --backports             "${LB_BACKPORTS}" \
#     --security              "${LB_SECURITY}" \
#     --updates               "${LB_UPDATES}" \
#     --firmware-binary       "${LB_FIRMWARE_BINARY}" \
#     --firmware-chroot       "${LB_FIRMWARE_CHROOT}" \
#     \
#     --architectures         "${LB_ARCHITECTURES}" \
#     --linux-flavours        "${LB_LINUX_FLAVOURS}" \
#     \
#     --cache                 "${LB_CACHE}" \
#     --cache-packages        "${LB_CACHE_PACKAGES}" \
#     --cache-stages          "${LB_CACHE_STAGES}" \
#     \
#     --image-name            "${ISO_FILENAME%.iso}" \
#     --color                 "${LB_COLORS}" \
#     "${@}"  # pass-through any extra flags

lb config --binary-image        "${LB_BINARY_IMAGES}" \
        --archive-areas         "${LB_APT_ARCHIVE_AREAS}" \
        --parent-archive-areas  "${LB_APT_ARCHIVE_AREAS}" \
        --mirror-bootstrap      "${LB_PARENT_MIRROR_BOOTSTRAP}" \
        --apt-source-archives   "${LB_APT_SOURCE_ARCHIVES}" \
        --backports             "${LB_BACKPORTS}" \
        --security              "${LB_SECURITY}" \
        --updates               "${LB_UPDATES}" \
        --clean \
        --color \
        --debootstrap-options   "--include=apt-transport-https,ca-certificates,openssl" \
        --distribution          "${LB_DISTRIBUTION}" \
        --firmware-binary       "${LB_FIRMWARE_BINARY}" \
        --firmware-chroot       "${LB_FIRMWARE_CHROOT}" \
        --image-name            "${ISO_FILENAME%.iso}" \
        --iso-application       "${DISTRO_NAME}" \
        --linux-flavours        "${LB_LINUX_FLAVOURS}" \
        --memtest               "${LB_MEMTEST}" \
        --bootloaders           "${LB_BOOTLOADERS}" \
        --bootappend-live "${LB_BOOTAPPEND_LIVE}" \
        "${@}" @>/dev/null




log_success "lb config assembled for profile: shopno-os-gaming-xfce"
