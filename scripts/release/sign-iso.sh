#!/usr/bin/env bash
# =============================================================================
# scripts/release/sign-iso.sh
# ShopnoOS - ISO Signer & Checksum Generator
#
# USAGE:
#   ./scripts/release/sign-iso.sh <path/to/shopno-os-*.iso>
#
# ENVIRONMENT VARIABLES:
#   OS_GPG_KEY     GPG key ID or fingerprint to sign with (required)
#   OS_GPG_BATCH   Set to '1' for non-interactive/CI signing (uses gpg-agent)
#
# WHAT IT DOES:
#   1. Verifies the ISO exists and is a valid ISO 9660 image
#   2. Generates SHA256 and SHA512 checksum files
#   3. Creates a detached GPG signature (.iso.gpg)
#   4. Writes a combined SHA256SUMS / SHA512SUMS manifest (multi-ISO friendly)
#   5. Verifies the signature was created correctly
#
# OUTPUT FILES (alongside the ISO):
#   shopno-os-1.0-core-none-amd64-20250301.sha256
#   shopno-os-1.0-core-none-amd64-20250301.sha512
#   shopno-os-1.0-core-none-amd64-20250301.iso.gpg
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISO_PATH="${1:-}"

if [[ -z "${ISO_PATH}" ]]; then
    log_error "Usage: $0 <path/to/shopno-os-*.iso>"
    log_error "  Environment: OS_GPG_KEY=<key-id>"
    exit 1
fi

require_file "${ISO_PATH}"
require_command gpg sha256sum sha512sum file

ISO_DIR="$(dirname "${ISO_PATH}")"
ISO_FILE="$(basename "${ISO_PATH}")"
ISO_STEM="${ISO_FILE%.iso}"

# ---------------------------------------------------------------------------
# Validate GPG key
# ---------------------------------------------------------------------------
GPG_KEY="${OS_GPG_KEY:-}"
GPG_BATCH="${OS_GPG_BATCH:-0}"

if [[ -z "${GPG_KEY}" ]]; then
    log_error "OS_GPG_KEY is not set."
    log_error "  Export the signing key ID before running:"
    log_error "    export OS_GPG_KEY=ABCD1234EFGH5678"
    log_error "  To list available keys: gpg --list-secret-keys"
    exit 1
fi

# Verify the key exists in the keyring
if ! gpg --list-secret-keys "${GPG_KEY}" &>/dev/null; then
    log_error "GPG key '${GPG_KEY}' not found in secret keyring."
    log_error "  Import it with: gpg --import <keyfile>"
    exit 1
fi

log_step "Signing ISO: ${ISO_FILE}"
log_info "  GPG key  : ${GPG_KEY}"
log_info "  ISO dir  : ${ISO_DIR}"

# ---------------------------------------------------------------------------
# Verify ISO sanity before touching it
# ---------------------------------------------------------------------------
FILE_TYPE="$(file -b "${ISO_PATH}")"
if ! echo "${FILE_TYPE}" | grep -qiE 'ISO 9660|x86 boot'; then
    log_error "File does not appear to be a valid ISO 9660 image."
    log_error "  file: ${FILE_TYPE}"
    log_error "  Path: ${ISO_PATH}"
    exit 1
fi
log_info "ISO type verified: ${FILE_TYPE:0:60}"

# ---------------------------------------------------------------------------
# Generate checksums
# ---------------------------------------------------------------------------
log_step "Generating checksums"

SHA256_FILE="${ISO_DIR}/${ISO_STEM}.sha256"
SHA512_FILE="${ISO_DIR}/${ISO_STEM}.sha512"

pushd "${ISO_DIR}" > /dev/null

    log_info "Computing SHA256..."
    sha256sum "${ISO_FILE}" > "${SHA256_FILE}"
    SHA256_HASH="$(awk '{print $1}' "${SHA256_FILE}")"
    log_success "SHA256: ${SHA256_HASH}"

    log_info "Computing SHA512..."
    sha512sum "${ISO_FILE}" > "${SHA512_FILE}"
    SHA512_HASH="$(awk '{print $1}' "${SHA512_FILE}")"
    log_success "SHA512: ${SHA512_HASH:0:64}..."

popd > /dev/null

# ---------------------------------------------------------------------------
# Update rolling SHA256SUMS / SHA512SUMS manifests (for multi-ISO releases)
# ---------------------------------------------------------------------------
SHA256SUMS_FILE="${ISO_DIR}/SHA256SUMS"
SHA512SUMS_FILE="${ISO_DIR}/SHA512SUMS"

# Remove previous entry for this ISO stem if it exists, then append
for manifest in "${SHA256SUMS_FILE}" "${SHA512SUMS_FILE}"; do
    [[ -f "${manifest}" ]] && grep -v "${ISO_FILE}" "${manifest}" > "${manifest}.tmp" \
        && mv "${manifest}.tmp" "${manifest}" || true
done

echo "${SHA256_HASH}  ${ISO_FILE}" >> "${SHA256SUMS_FILE}"
echo "${SHA512_HASH}  ${ISO_FILE}" >> "${SHA512SUMS_FILE}"
log_info "Updated: SHA256SUMS"
log_info "Updated: SHA512SUMS"

# ---------------------------------------------------------------------------
# GPG sign
# ---------------------------------------------------------------------------
log_step "Creating GPG detached signature"

SIG_FILE="${ISO_PATH}.gpg"
[[ -f "${SIG_FILE}" ]] && rm -f "${SIG_FILE}"

GPG_SIGN_ARGS=(
    --armor
    --detach-sign
    --local-user "${GPG_KEY}"
    --output "${SIG_FILE}"
)

if [[ "${GPG_BATCH}" == "1" ]]; then
    GPG_SIGN_ARGS+=(--batch --no-tty --pinentry-mode loopback)
fi

gpg "${GPG_SIGN_ARGS[@]}" "${ISO_PATH}"
log_success "Signature written: ${SIG_FILE}"

# ---------------------------------------------------------------------------
# Verify the signature we just created
# ---------------------------------------------------------------------------
log_step "Verifying signature"

if gpg --verify "${SIG_FILE}" "${ISO_PATH}" 2>&1 | tee /dev/stderr | grep -q "Good signature"; then
    log_success "Signature verification passed."
else
    log_error "Signature verification FAILED."
    log_error "  Check that the signing key '${GPG_KEY}' is the one in the keyring."
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Signing complete"
log_info "  ISO       : ${ISO_PATH}"
log_info "  SHA256    : ${SHA256_FILE}"
log_info "  SHA512    : ${SHA512_FILE}"
log_info "  Signature : ${SIG_FILE}"
log_info "  SHA256SUMS: ${SHA256SUMS_FILE}"
log_success "All artifacts signed and checksummed."
