#!/usr/bin/env bash
# =============================================================================
# scripts/build/stamp-iso.sh
# ShopnoOS — ISO Metadata Stamper
#
# USAGE:
#   ./scripts/build/stamp-iso.sh <build-dir> <iso-filename>
#
# PURPOSE:
#   After lb build produces the raw ISO, this script:
#     1. Renames the ISO to the canonical Naming Law filename
#     2. Embeds build metadata as a readable file inside the ISO
#        (visible at /.shopno-os-build-info when the ISO is mounted)
#     3. Writes a build-manifest.json alongside the ISO for release tooling
#     4. Verifies the ISO is bootable (basic sanity check)
#
# The embedded metadata makes every ISO self-documenting:
#   mount -o loop shopno-os-1.0-core-none-amd64-20250301.iso /mnt
#   cat /mnt/.shopno-os-build-info
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

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
BUILD_DIR="${1:-}"
ISO_FILENAME="${2:-}"

[[ -z "${BUILD_DIR}"    ]] && { log_error "Usage: $0 <build-dir> <iso-filename>"; exit 1; }
[[ -z "${ISO_FILENAME}" ]] && { log_error "Usage: $0 <build-dir> <iso-filename>"; exit 1; }

require_dir "${BUILD_DIR}"
require_command xorriso file

# ---------------------------------------------------------------------------
# Locate the ISO produced by lb build
# live-build names the output based on lb --image-name; find it.
# ---------------------------------------------------------------------------
log_step "Locating lb build output ISO"

LB_ISO=""
# live-build typically places the ISO in the build dir root
while IFS= read -r -d '' candidate; do
    LB_ISO="${candidate}"
    break
done < <(find "${BUILD_DIR}" -maxdepth 1 -name "*.iso" -print0 2>/dev/null | sort -z)

if [[ -z "${LB_ISO}" ]]; then
    log_error "No ISO file found in ${BUILD_DIR}"
    log_error "lb build may have failed — check ${BUILD_DIR}/build.log"
    exit 1
fi

log_info "Found ISO: ${LB_ISO}"

# ---------------------------------------------------------------------------
# Rename to canonical Naming Law filename
# ---------------------------------------------------------------------------
CANONICAL_ISO="${BUILD_DIR}/${ISO_FILENAME}"

if [[ "${LB_ISO}" != "${CANONICAL_ISO}" ]]; then
    log_info "Renaming: $(basename "${LB_ISO}") → ${ISO_FILENAME}"
    mv "${LB_ISO}" "${CANONICAL_ISO}"
fi

log_success "ISO at canonical path: ${CANONICAL_ISO}"

# ---------------------------------------------------------------------------
# Sanity check: verify this is actually an ISO 9660 / hybrid image
# ---------------------------------------------------------------------------
log_step "Verifying ISO integrity"

FILE_TYPE="$(file -b "${CANONICAL_ISO}")"
log_info "file(1) output: ${FILE_TYPE}"

if ! echo "${FILE_TYPE}" | grep -qiE 'ISO 9660|x86 boot'; then
    log_error "Output file does not appear to be a valid ISO 9660 image."
    log_error "  file: ${FILE_TYPE}"
    log_error "  Path: ${CANONICAL_ISO}"
    exit 1
fi

ISO_SIZE="$(du -sh "${CANONICAL_ISO}" | cut -f1)"
log_info "ISO size: ${ISO_SIZE}"
log_success "ISO integrity check passed."

# ---------------------------------------------------------------------------
# Build metadata env block (for embedding and manifest)
# ---------------------------------------------------------------------------
BUILD_DATE="$(iso_build_date)"
BUILD_METADATA="$(iso_metadata_env)"

# ---------------------------------------------------------------------------
# Embed metadata into the ISO as /.shopno-os-build-info
# We use xorriso in "jigdo-like" mode to add one file without rebuilding.
# ---------------------------------------------------------------------------
log_step "Embedding build metadata into ISO"

# Write the metadata to a temp file
TMP_META="$(mktemp /tmp/shopno-os-build-info.XXXXXX)"
trap 'rm -f "${TMP_META}"' EXIT

cat > "${TMP_META}" <<EOF
${BUILD_METADATA}
# --- Human-readable summary ---
# ${DISTRO_NAME} ${DISTRO_VERSION} (${DISTRO_CODENAME})
# Edition  : ${DISTRO_EDITION}
# Flavor   : ${DISTRO_FLAVOR}
# Hardware : ${DISTRO_HARDWARE}
# Arch     : ${DISTRO_ARCH}
# Built    : ${BUILD_DATE}
# Filename : ${ISO_FILENAME}
EOF

# Use xorriso to add the file to the ISO in-place
xorriso \
    -dev "${CANONICAL_ISO}" \
    -boot_image any keep \
    -map "${TMP_META}" "/.shopno-os-build-info" \
    -commit \
    2>/dev/null \
    && log_success "Metadata embedded at /.shopno-os-build-info" \
    || log_warn "xorriso embed failed (non-fatal — ISO is still valid)"

# ---------------------------------------------------------------------------
# Write build-manifest.json alongside the ISO
# ---------------------------------------------------------------------------
log_step "Writing build-manifest.json"

MANIFEST="${BUILD_DIR}/build-manifest.json"

# Compute size in bytes
ISO_BYTES="$(stat -c '%s' "${CANONICAL_ISO}" 2>/dev/null || stat -f '%z' "${CANONICAL_ISO}")"

# Pre-compute SHA256 for the manifest (sign-iso.sh will write the .sha256 file)
SHA256="$(sha256sum "${CANONICAL_ISO}" | awk '{print $1}')"

jq -n \
    --arg schema_version  "1" \
    --arg name            "${DISTRO_NAME}" \
    --arg id              "${DISTRO_ID}" \
    --arg version         "${DISTRO_VERSION}" \
    --arg codename        "${DISTRO_CODENAME}" \
    --arg edition         "${DISTRO_EDITION}" \
    --arg flavor          "${DISTRO_FLAVOR}" \
    --arg hardware        "${DISTRO_HARDWARE}" \
    --arg arch            "${DISTRO_ARCH}" \
    --arg distribution    "${LB_DISTRIBUTION}" \
    --arg build_date      "${BUILD_DATE}" \
    --arg iso_filename    "${ISO_FILENAME}" \
    --arg iso_sha256      "${SHA256}" \
    --argjson iso_bytes   "${ISO_BYTES}" \
    --arg volume_label    "$(iso_volume_label)" \
    '{
        schema_version: $schema_version,
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
            distribution: $distribution,
            date:         $build_date
        },
        output: {
            filename:     $iso_filename,
            volume_label: $volume_label,
            size_bytes:   $iso_bytes,
            sha256:       $iso_sha256
        }
    }' > "${MANIFEST}"

log_success "Manifest written: ${MANIFEST}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_success "stamp-iso complete."
log_info "  ISO      : ${CANONICAL_ISO}"
log_info "  Manifest : ${MANIFEST}"
log_info "  Size     : ${ISO_SIZE}"
log_info "  SHA256   : ${SHA256}"
