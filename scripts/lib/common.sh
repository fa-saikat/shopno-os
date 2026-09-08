#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh
# ShopnoOS - Shared Script Library: Common Utilities
#
# PURPOSE:
#   Mandatory source for every script in the ShopnoOS build system.
#   Provides: logging, colors, error trapping, guard checks and general
#   utility functions. Nothing distro-specific lives here.
#
# USAGE:
#   source "$(dirname "$0")/../lib/common.sh"
#
# GUARDS:
#   Safe to source multiple times - idempotent via LIB_COMMON_LOADED.
# =============================================================================

[[ -n "${LIB_COMMON_LOADED:-}" ]] && return 0
readonly LIB_COMMON_LOADED=1

# =============================================================================
# STRICT MODE
# =============================================================================
set -euo pipefail
# Inherit ERR trap in subshells and functions
set -E

# =============================================================================
# ANSI COLOR CODES
# Disabled automatically when stdout is not a TTY (e.g. CI logs, pipes)
# =============================================================================
if [[ -t 1 ]]; then
    readonly CLR_RESET="\033[0m"
    readonly CLR_BOLD="\033[1m"
    readonly CLR_DIM="\033[2m"

    readonly CLR_RED="\033[0;31m"
    readonly CLR_GREEN="\033[0;32m"
    readonly CLR_YELLOW="\033[0;33m"
    readonly CLR_BLUE="\033[0;34m"
    readonly CLR_MAGENTA="\033[0;35m"
    readonly CLR_CYAN="\033[0;36m"
    readonly CLR_WHITE="\033[0;37m"

    readonly CLR_BOLD_RED="\033[1;31m"
    readonly CLR_BOLD_GREEN="\033[1;32m"
    readonly CLR_BOLD_YELLOW="\033[1;33m"
    readonly CLR_BOLD_CYAN="\033[1;36m"
else
    readonly CLR_RESET=""
    readonly CLR_BOLD=""
    readonly CLR_DIM=""
    readonly CLR_RED=""
    readonly CLR_GREEN=""
    readonly CLR_YELLOW=""
    readonly CLR_BLUE=""
    readonly CLR_MAGENTA=""
    readonly CLR_CYAN=""
    readonly CLR_WHITE=""
    readonly CLR_BOLD_RED=""
    readonly CLR_BOLD_GREEN=""
    readonly CLR_BOLD_YELLOW=""
    readonly CLR_BOLD_CYAN=""
fi

# =============================================================================
# LOGGING
# All log output goes to stderr so stdout can carry actual data/results.
# =============================================================================

# Internal: timestamp prefix
_log_ts() {
    date "+%H:%M:%S"
}

# log_info "message"       → [ 12:34:56 INFO  ] message
log_info() {
    echo -e "${CLR_DIM}[$(_log_ts)]${CLR_RESET} ${CLR_BOLD_CYAN}INFO ${CLR_RESET} $*" >&2
}

# log_success "message"    → [ 12:34:56 OK    ] message
log_success() {
    echo -e "${CLR_DIM}[$(_log_ts)]${CLR_RESET} ${CLR_BOLD_GREEN}OK   ${CLR_RESET} $*" >&2
}

# log_warn "message"       → [ 12:34:56 WARN  ] message
log_warn() {
    echo -e "${CLR_DIM}[$(_log_ts)]${CLR_RESET} ${CLR_BOLD_YELLOW}WARN ${CLR_RESET} $*" >&2
}

# log_error "message"      → [ 12:34:56 ERROR ] message
log_error() {
    echo -e "${CLR_DIM}[$(_log_ts)]${CLR_RESET} ${CLR_BOLD_RED}ERROR${CLR_RESET} $*" >&2
}

# log_step "message"       → section header divider
log_step() {
    echo -e "\n${CLR_BOLD}${CLR_BLUE}══════════════════════════════════════════════${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}${CLR_BLUE}  $*${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}${CLR_BLUE}══════════════════════════════════════════════${CLR_RESET}\n" >&2
}

# log_debug "message"      → only printed when LIB_DEBUG=1
log_debug() {
    [[ "${LIB_DEBUG:-0}" == "1" ]] || return 0
    echo -e "${CLR_DIM}[$(_log_ts)] DEBUG $*${CLR_RESET}" >&2
}

# =============================================================================
# ERROR TRAPPING
# =============================================================================

# Called automatically on ERR (via set -E + trap below)
_err_handler() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]}
    local command="${BASH_COMMAND}"
    local script="${BASH_SOURCE[1]:-unknown}"

    log_error "Command failed with exit code ${exit_code}"
    log_error "  Script : ${script}"
    log_error "  Line   : ${line_no}"
    log_error "  Command: ${command}"

    # Print a simple stack trace
    local i
    echo -e "${CLR_BOLD_RED}Stack trace:${CLR_RESET}" >&2
    for (( i=1; i<${#BASH_SOURCE[@]}; i++ )); do
        echo -e "  ${CLR_DIM}#${i} ${BASH_SOURCE[$i]}:${BASH_LINENO[$i-1]} in ${FUNCNAME[$i]:-main}${CLR_RESET}" >&2
    done
}

trap '_err_handler' ERR

# =============================================================================
# GUARD / PRECONDITION UTILITIES
# =============================================================================

# require_root - die if not running as root
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root (got UID=${EUID})."
        log_error "Use: sudo $0 $*"
        exit 1
    fi
}

# require_command "cmd" ["cmd2" ...]  - die if any command is not in PATH
require_command() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required command(s) not found: ${missing[*]}"
        log_error "Install the missing packages and retry."
        exit 1
    fi
}

# require_var "VAR_NAME" ["VAR_NAME2" ...]  - die if any variable is unset or empty
require_var() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required variable(s) are unset or empty: ${missing[*]}"
        exit 1
    fi
}

# require_file "path" ["path2" ...]  - die if any file does not exist
require_file() {
    local missing=()
    for f in "$@"; do
        [[ -f "${f}" ]] || missing+=("${f}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required file(s) not found:"
        for f in "${missing[@]}"; do
            log_error "  ${f}"
        done
        exit 1
    fi
}

# require_dir "path" ["path2" ...]  - die if any directory does not exist
require_dir() {
    local missing=()
    for d in "$@"; do
        [[ -d "${d}" ]] || missing+=("${d}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required directory/directories not found:"
        for d in "${missing[@]}"; do
            log_error "  ${d}"
        done
        exit 1
    fi
}

# =============================================================================
# REPO ROOT RESOLUTION
# Every script can call _repo_root to get an absolute path to the repo,
# regardless of where it is called from.
# =============================================================================

# _repo_root - prints absolute path to repo root (the dir containing scripts/)
_repo_root() {
    local this_file
    this_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # lib/ is inside scripts/, which is inside repo root
    echo "$(dirname "$(dirname "${this_file}")")"
}

# Convenience export - most scripts will want this
OS_REPO_ROOT="$(_repo_root)"
export OS_REPO_ROOT

# =============================================================================
# GENERAL UTILITIES
# =============================================================================

# die "message" [exit_code]  - print error and exit
die() {
    local msg="${1:-Unspecified error}"
    local code="${2:-1}"
    log_error "${msg}"
    exit "${code}"
}

# confirm "question"  - prompt y/N, returns 0 on yes, 1 on no
confirm() {
    local question="${1:-Are you sure?}"
    local reply
    read -r -p "$(echo -e "${CLR_YELLOW}${question} [y/N]: ${CLR_RESET}")" reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# _symlink src dst  - create symlink; warn and skip if dst already exists
_symlink() {
    local src="${1}"
    local dst="${2}"
    if [[ -L "${dst}" ]]; then
        log_debug "Symlink already exists, skipping: ${dst}"
        return 0
    fi
    if [[ -e "${dst}" ]]; then
        log_warn "Destination exists and is not a symlink: ${dst} - skipping"
        return 0
    fi
    ln -s "${src}" "${dst}"
    log_debug "Symlinked: ${dst} → ${src}"
}

# _run cmd [args...]  - log then execute a command
_run() {
    log_debug "Running: $*"
    "$@"
}

# iso_build_date  - prints current UTC date as YYYYMMDD
iso_build_date() {
    date -u "+%Y%m%d"
}

# =============================================================================
# ENVIRONMENT SUMMARY (debug helper)
# =============================================================================

# dump_env  - print all LIB_* and DISTRO_* vars (only when LIB_DEBUG=1)
dump_env() {
    [[ "${LIB_DEBUG:-0}" == "1" ]] || return 0
    echo -e "${CLR_DIM}--- Environment Dump ---${CLR_RESET}" >&2
    env | grep -E '^(LIB_|DISTRO_|LB_)' | sort | while IFS= read -r line; do
        echo -e "  ${CLR_DIM}${line}${CLR_RESET}" >&2
    done
    echo -e "${CLR_DIM}------------------------${CLR_RESET}" >&2
}
