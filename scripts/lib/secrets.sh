#!/usr/bin/env bash
# =============================================================================
# scripts/lib/secrets.sh
# ShopnoOS - Shared Script Library: Secrets Loader
#
# PURPOSE:
#   Loads all secrets from secrets/*.env files, exports them into the
#   environment for use by all build and release scripts, then prints
#   a capability summary showing what the build can and cannot do.
#
# USAGE:
#   source "$(dirname "$0")/../lib/secrets.sh"
#
# DEPENDS ON:
#   common.sh (must be sourced first)
#
# BEHAVIOR:
#   - Each secrets file is OPTIONAL - missing files are warned, not fatal
#   - Variables are exported so all child processes (sign-iso.sh etc.) inherit them
#   - Idempotent - safe to source multiple times
#
# SECRETS FILES:
#   secrets/signing.env            → ISO GPG signing
#   secrets/repo-signing.env       → APT repository GPG signing
#   secrets/mirror-credentials.env → Release mirror / upload credentials
#   secrets/notary.env             → Secure Boot / MOK signing
#   secrets/github-token.env       → GitHub / Forgejo API token
# =============================================================================

[[ -n "${OS_SECRETS_LOADED:-}" ]] && return 0
readonly OS_SECRETS_LOADED=1

# Ensure common.sh was sourced
if [[ -z "${OS_COMMON_LOADED:-}" ]]; then
    echo "[secrets.sh] ERROR: common.sh must be sourced before secrets.sh" >&2
    exit 1
fi

# =============================================================================
# SECRETS DIRECTORY
# =============================================================================

readonly OS_SECRETS_DIR="${OS_REPO_ROOT}/secrets"

# =============================================================================
# INTERNAL LOADER
# =============================================================================

# _load_secrets_file "path" "label"
# Sources a single secrets file if it exists. Warns if missing.
# Returns 0 if loaded, 1 if not found.
_load_secrets_file() {
    local secrets_file="${1}"
    local label="${2}"

    if [[ ! -f "${secrets_file}" ]]; then
        return 1
    fi

    log_debug "Loading secrets: ${label} (${secrets_file})"
    # shellcheck source=/dev/null
    source "${secrets_file}"
    return 0
}

# =============================================================================
# LOAD ALL SECRETS FILES
# =============================================================================

load_secrets() {
    log_step "Loading secrets"

    # signing.env - ISO GPG signing key
    if _load_secrets_file "${OS_SECRETS_DIR}/signing.env" "ISO signing"; then
        export OS_GPG_KEY
        export OS_GPG_BATCH
        _SECRET_SIGNING_LOADED=1
    else
        _SECRET_SIGNING_LOADED=0
    fi

    # repo-signing.env - APT repository GPG signing key
    if _load_secrets_file "${OS_SECRETS_DIR}/repo-signing.env" "APT repo signing"; then
        export OS_REPO_GPG_KEY
        export OS_REPO_GPG_BATCH
        _SECRET_REPO_SIGNING_LOADED=1
    else
        _SECRET_REPO_SIGNING_LOADED=0
    fi

    # mirror-credentials.env - release mirror upload credentials
    if _load_secrets_file "${OS_SECRETS_DIR}/mirror-credentials.env" "Mirror credentials"; then
        export OS_MIRROR_HOST
        export OS_MIRROR_USER
        export OS_MIRROR_PATH
        export OS_MIRROR_SSH_KEY
        export OS_S3_BUCKET
        export OS_S3_ENDPOINT
        export OS_S3_ACCESS_KEY
        export OS_S3_SECRET_KEY
        export OS_S3_REGION
        _SECRET_MIRROR_LOADED=1
    else
        _SECRET_MIRROR_LOADED=0
    fi

    # notary.env - Secure Boot / MOK signing
    if _load_secrets_file "${OS_SECRETS_DIR}/notary.env" "Secure Boot / MOK"; then
        export OS_SECUREBOOT
        export OS_MOK_KEY
        export OS_MOK_CERT
        _SECRET_NOTARY_LOADED=1
    else
        _SECRET_NOTARY_LOADED=0
    fi

    # github-token.env - GitHub / Forgejo API token
    if _load_secrets_file "${OS_SECRETS_DIR}/github-token.env" "GitHub token"; then
        export OS_GITHUB_TOKEN
        export OS_GITHUB_REPO
        export OS_GITHUB_API_URL
        _SECRET_GITHUB_LOADED=1
    else
        _SECRET_GITHUB_LOADED=0
    fi

    _secrets_capability_summary
}

# =============================================================================
# CAPABILITY SUMMARY
# =============================================================================

# _capability_line "label" "loaded_flag" "env_file"
# Prints a single INFO line showing whether a capability is available.
_capability_line() {
    local label="${1}"
    local loaded="${2}"
    local env_file="${3}"

    if [[ "${loaded}" == "1" ]]; then
        log_info "  ${label}: true   (${env_file})"
    else
        log_info "  ${label}: false  (${env_file} not found)"
    fi
}

_secrets_capability_summary() {
    log_step "Build Capabilities"

    _capability_line \
        "ISO signing  " "${_SECRET_SIGNING_LOADED}"      "signing.env"
    _capability_line \
        "APT repo sign" "${_SECRET_REPO_SIGNING_LOADED}" "repo-signing.env"
    _capability_line \
        "Mirror upload" "${_SECRET_MIRROR_LOADED}"        "mirror-credentials.env"
    _capability_line \
        "Secure Boot  " "${_SECRET_NOTARY_LOADED}"        "notary.env"
    _capability_line \
        "GitHub token " "${_SECRET_GITHUB_LOADED}"        "github-token.env"
}

# =============================================================================
# DO NOT AUTO-LOAD on source
# If done so, it auto-loads and prints the capability summary in the middle of
# the profile loading output, which is noisy.
# =============================================================================
# load_secrets
