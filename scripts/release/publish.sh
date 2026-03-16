#!/usr/bin/env bash
# =============================================================================
# scripts/release/publish.sh
# ShopnoOS  — Release Publisher
#
# USAGE:
#   ./scripts/release/publish.sh <profile-name> [options]
#   ./scripts/release/publish.sh shopno-os-core
#   ./scripts/release/publish.sh shopno-os-desktop-gnome --dry-run
#
# ENVIRONMENT VARIABLES (required unless --dry-run):
#   SHOPNOOS_PUBLISH_HOST      SSH host of the mirror server
#   SHOPNOOS_PUBLISH_USER      SSH user
#   SHOPNOOS_PUBLISH_PATH      Remote base path  (e.g. /srv/mirror/abrar)
#   SHOPNOOS_PUBLISH_KEY       Path to SSH private key (optional — uses ssh-agent otherwise)
#
# WHAT IT PUBLISHES:
#   - The ISO
#   - .sha256, .sha512 checksum files
#   - .iso.gpg signature
#   - build-manifest.json
#   - SHA256SUMS, SHA512SUMS (rolling manifests)
#
# REMOTE LAYOUT:
#   <SHOPNOOS_PUBLISH_PATH>/
#   └── <VERSION>/
#       └── <ARCH>/
#           ├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<DATE>.iso
#           ├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<DATE>.sha256
#           ├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<DATE>.sha512
#           ├── shopno-os-<VERSION>-<EDITION>-<FLAVOR>-<ARCH>-<DATE>.iso.gpg
#           ├── build-manifest.json
#           ├── SHA256SUMS
#           └── SHA512SUMS
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
PROFILE_NAME="${1:-}"
OPT_DRY_RUN=0
OPT_OUTPUT_DIR=""

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <profile-name> [options]

Options:
  --output-dir D   Override local output dir (default: build/output/)
  --dry-run        Show what would be uploaded, do not transfer
  -h, --help       Show this help

Required environment (unless --dry-run):
  SHOPNOOS_PUBLISH_HOST   Mirror server SSH host
  SHOPNOOS_PUBLISH_USER   SSH user
  SHOPNOOS_PUBLISH_PATH   Remote base path
  SHOPNOOS_PUBLISH_KEY    SSH private key path (optional)
EOF
    exit 1
}

[[ $# -eq 0 ]] && _usage
shift  # consume profile name from initial positional capture above

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --dry-run)     OPT_DRY_RUN=1 ;;
        --output-dir)  OPT_OUTPUT_DIR="${2}"; shift ;;
        -h|--help)     _usage ;;
        *) log_error "Unknown option: ${1}"; _usage ;;
    esac
    shift
done

[[ -z "${PROFILE_NAME}" ]] && { log_error "Profile name required."; _usage; }

# ---------------------------------------------------------------------------
# Load profile
# ---------------------------------------------------------------------------
load_profile "${PROFILE_NAME}"

ISO_FILENAME="$(iso_name)"
OUTPUT_DIR="${OPT_OUTPUT_DIR:-${LIB_REPO_ROOT}/build/output}"

# ---------------------------------------------------------------------------
# Locate artifacts
# ---------------------------------------------------------------------------
log_step "Locating release artifacts"

declare -a ARTIFACTS=()
declare -a MISSING=()

_add_artifact() {
    local path="${1}"
    local required="${2:-true}"
    if [[ -f "${path}" ]]; then
        ARTIFACTS+=("${path}")
        log_info "  Found: $(basename "${path}")"
    elif [[ "${required}" == "true" ]]; then
        MISSING+=("$(basename "${path}")")
        log_error "  Missing (required): ${path}"
    else
        log_warn "  Missing (optional): $(basename "${path}")"
    fi
}

_add_artifact "${OUTPUT_DIR}/${ISO_FILENAME}"                         true
_add_artifact "${OUTPUT_DIR}/$(iso_checksum_filename sha256)"         true
_add_artifact "${OUTPUT_DIR}/$(iso_checksum_filename sha512)"         true
_add_artifact "${OUTPUT_DIR}/$(iso_signature_filename)"               true
_add_artifact "${OUTPUT_DIR}/build-manifest.json"                     false
_add_artifact "${OUTPUT_DIR}/SHA256SUMS"                              false
_add_artifact "${OUTPUT_DIR}/SHA512SUMS"                              false

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_error "Required artifact(s) missing — cannot publish."
    log_error "  Run a full build first: ./scripts/build/build.sh ${PROFILE_NAME}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_step "DRY RUN — would publish:"
    REMOTE_HOST="${SHOPNOOS_PUBLISH_HOST:-<host>}"
    REMOTE_USER="${SHOPNOOS_PUBLISH_USER:-<user>}"
    REMOTE_PATH="${SHOPNOOS_PUBLISH_PATH:-<path>}"
    REMOTE_DIR="${REMOTE_PATH}/${DISTRO_VERSION}/${DISTRO_ARCH}"

    for artifact in "${ARTIFACTS[@]}"; do
        echo "  rsync $(basename "${artifact}") → ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
    done
    log_warn "Dry run complete — no files transferred."
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate publish environment
# ---------------------------------------------------------------------------
require_command rsync ssh

PUBLISH_HOST="${SHOPNOOS_PUBLISH_HOST:-}"
PUBLISH_USER="${SHOPNOOS_PUBLISH_USER:-}"
PUBLISH_PATH="${SHOPNOOS_PUBLISH_PATH:-}"
PUBLISH_KEY="${SHOPNOOS_PUBLISH_KEY:-}"

require_var PUBLISH_HOST PUBLISH_USER PUBLISH_PATH

# ---------------------------------------------------------------------------
# Build SSH args
# ---------------------------------------------------------------------------
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
[[ -n "${PUBLISH_KEY}" ]] && SSH_OPTS+=(-i "${PUBLISH_KEY}")

REMOTE_DIR="${PUBLISH_PATH}/${DISTRO_VERSION}/${DISTRO_ARCH}"
REMOTE_TARGET="${PUBLISH_USER}@${PUBLISH_HOST}"

# ---------------------------------------------------------------------------
# Create remote directory
# ---------------------------------------------------------------------------
log_step "Preparing remote directory: ${REMOTE_TARGET}:${REMOTE_DIR}"
ssh "${SSH_OPTS[@]}" "${REMOTE_TARGET}" "mkdir -p '${REMOTE_DIR}'"

# ---------------------------------------------------------------------------
# Transfer artifacts
# ---------------------------------------------------------------------------
log_step "Uploading artifacts (${#ARTIFACTS[@]} files)"

RSYNC_OPTS=(
    -av
    --progress
    --checksum           # compare by checksum, not mtime (ISO mtime changes)
    -e "ssh ${SSH_OPTS[*]}"
)

rsync "${RSYNC_OPTS[@]}" \
    "${ARTIFACTS[@]}" \
    "${REMOTE_TARGET}:${REMOTE_DIR}/"

log_success "Upload complete."

# ---------------------------------------------------------------------------
# Remote: update symlinks  (latest → <DATE>)
# ---------------------------------------------------------------------------
log_step "Updating 'latest' symlinks on mirror"

ISO_STEM="$(iso_stem)"
LATEST_STEM="${DISTRO_ID}-${DISTRO_VERSION}-${DISTRO_EDITION}-${DISTRO_FLAVOR}-${DISTRO_ARCH}-latest"

ssh "${SSH_OPTS[@]}" "${REMOTE_TARGET}" bash <<REMOTE_SCRIPT
set -euo pipefail
cd '${REMOTE_DIR}'

# ISO
[[ -f '${ISO_FILENAME}' ]] && ln -sf '${ISO_FILENAME}' '${LATEST_STEM}.iso'

# Checksums
[[ -f '${ISO_STEM}.sha256' ]] && ln -sf '${ISO_STEM}.sha256' '${LATEST_STEM}.sha256'
[[ -f '${ISO_STEM}.sha512' ]] && ln -sf '${ISO_STEM}.sha512' '${LATEST_STEM}.sha512'
[[ -f '${ISO_FILENAME}.gpg' ]] && ln -sf '${ISO_FILENAME}.gpg' '${LATEST_STEM}.iso.gpg'

echo "Latest symlinks updated."
REMOTE_SCRIPT

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Publish complete"
log_success "Released: ${ISO_FILENAME}"
log_info "  Mirror : https://${PUBLISH_HOST}/$(basename "${PUBLISH_PATH}")/${DISTRO_VERSION}/${DISTRO_ARCH}/"
log_info "  Latest : https://${PUBLISH_HOST}/$(basename "${PUBLISH_PATH}")/${DISTRO_VERSION}/${DISTRO_ARCH}/${LATEST_STEM}.iso"
