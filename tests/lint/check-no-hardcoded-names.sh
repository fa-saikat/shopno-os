#!/usr/bin/env bash
# =============================================================================
# tests/lint/check-no-hardcoded-names.sh
# ShopnoOS - Lint: Hardcoded Distro Name / URL Detection
#
# PURPOSE:
#   Enforce the branding isolation rule: nothing outside brand/identity/*.env
#   and brand/assets/ should contain hardcoded distro names, codenames,
#   version strings, or domain URLs.
#   Every reference must flow through DISTRO_* variables sourced from brand.sh.
#
# WHAT IS CHECKED:
#   Patterns like literal "ShopnoOS", "Jadu-Linux", "shopno-os.org",
#   hardcoded version strings (e.g. "1.0", "2.0") in contexts that suggest
#   they are identity values rather than package version constraints.
#
# WHAT IS EXCLUDED:
#   - brand/           (canonical source — allowed)
#   - docs/            (documentation — allowed to mention names)
#   - *.md             (markdown docs — allowed)
#   - CHANGELOG.md, README.md, CONTRIBUTING.md (project meta)
#   - .git/            (always skipped)
#   - build/           (generated artifacts)
#   - tests/           (this very directory)
#   - tools/           (should skip by design)
#
# EXIT CODES:
#   0 — no violations found
#   1 — violations detected (or usage error)
#
# USAGE:
#   ./tests/lint/check-no-hardcoded-names.sh [--repo-root <path>] [--strict]
#
# FLAGS:
#   --repo-root <path>   Override repo root detection
#   --strict             Also flag partial matches (e.g. "shopno-os" alone in configs)
#   --quiet              Summary only
#   --color / --no-color
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QUIET=0
STRICT=0
COLOR="auto"

# ---------------------------------------------------------------------------
# Known-safe exclusions - structural, not branding violations
# ---------------------------------------------------------------------------
# The standard "# ShopnoOS - <title>" header line used in every script/hook.
# Purely descriptive & doesn't affect the rebrand pipeline.
_is_header_title_line() {
    local content="${1}"
    [[ "${content}" =~ ^[[:space:]]*\#[[:space:]]*${DISTRO_NAME}[[:space:]]*[-–—] ]]
}

# Explicit inline suppression for one-off cases (use sparingly, comment why):
#   LB_DISTRIBUTION="trixie"  # shopno-os-lint:ignore
_has_ignore_marker() {
    local content="${1}"
    [[ "${content}" == *"shopno-os-lint:ignore"* ]]
}

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --repo-root) REPO_ROOT="${2}"; shift 2 ;;
        --strict)    STRICT=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        --color)     COLOR="always"; shift ;;
        --no-color)  COLOR="never"; shift ;;
        -h|--help)
            sed -n '2,/^# ====/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: ${1}" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_use_color() {
    [[ "${COLOR}" == "always" ]] && return 0
    [[ "${COLOR}" == "never"  ]] && return 1
    [[ -t 1 ]]
}

RED=""; YELLOW=""; GREEN=""; BOLD=""; DIM=""; RESET=""
if _use_color; then
    RED="\033[0;31m"; YELLOW="\033[0;33m"; GREEN="\033[0;32m"
    BOLD="\033[1m";   DIM="\033[2m";       RESET="\033[0m"
fi

log_ok()      { echo -e "  ${GREEN}[ok]${RESET}    ${*}"; }
log_error()   { echo -e "  ${RED}[FAIL]${RESET}  ${*}" >&2; }
log_info()    { echo -e "  ${DIM}[info]${RESET}  ${*}"; }
log_section() { echo -e "\n${BOLD}${*}${RESET}"; }

# ---------------------------------------------------------------------------
# Load brand vars to know what names/URLs to search for
# They may not exist yet in CI — fall back to safe defaults.
# ---------------------------------------------------------------------------
BRAND_NAME_ENV="${REPO_ROOT}/brand/identity/name.env"
BRAND_URLS_ENV="${REPO_ROOT}/brand/identity/urls.env"

DISTRO_NAME="${DISTRO_NAME:-ShopnoOS}"
DISTRO_CODENAME="${DISTRO_CODENAME:-trixie}"
DISTRO_VERSION="${DISTRO_VERSION:-1.0}"
DISTRO_ID="${DISTRO_ID:-shopno}"
DISTRO_WEBSITE="${DISTRO_WEBSITE:-https://jadupc.com/}"

if [[ -f "${BRAND_NAME_ENV}" ]]; then
    # shellcheck source=/dev/null
    source "${BRAND_NAME_ENV}"
fi
if [[ -f "${BRAND_URLS_ENV}" ]]; then
    # shellcheck source=/dev/null
    source "${BRAND_URLS_ENV}"
fi

# Strip protocol from website for pattern matching
_website_domain="${DISTRO_WEBSITE#https://}"
_website_domain="${_website_domain#http://}"
_website_domain="${_website_domain%%/*}"

# ---------------------------------------------------------------------------
# Build patterns to search for
# ---------------------------------------------------------------------------
# Each pattern is a grep -E extended regex
PATTERNS=(
    # Exact distro name (case-insensitive handled via grep -i below)
    "${DISTRO_NAME}"
    # Hyphenated variant
    "${DISTRO_NAME// /-}"
    # Codename as a standalone word (common in grub/plymouth configs)
    "\\b${DISTRO_CODENAME}\\b"
    # Website domain
    "${_website_domain}"
    # Hardcoded version in assignment context: VERSION="1.0" or version=1.0
    "[Vv][Ee][Rr][Ss][Ii][Oo][Nn][[:space:]]*=[[:space:]]*[\"']?${DISTRO_VERSION}[\"']?"
)

if [[ "${STRICT}" -eq 1 ]]; then
    # Also catch bare DISTRO_ID as a standalone word in non-variable contexts
    # e.g. NAME="shopno-os" in a hook — but not $DISTRO_ID or ${DISTRO_ID}
    PATTERNS+=(
        "(?<!\\\$\{?)(?<!\\\$)\\b${DISTRO_ID}\\b(?![\"']?\s*\})"
    )
fi

# ---------------------------------------------------------------------------
# Define which files to scan
# Exclude: brand/, docs/, *.md, .git/, build/, tests/
# ---------------------------------------------------------------------------
EXCLUDE_DIRS=(
    "${REPO_ROOT}/.git"
    "${REPO_ROOT}/brand"
    "${REPO_ROOT}/docs"
    "${REPO_ROOT}/build"
    "${REPO_ROOT}/tests"
    "${REPO_ROOT}/tools"
    "${REPO_ROOT}/secrets/_template"    # human setup docs, never built
    "${REPO_ROOT}/editions/*/config"    # chroot files
)

EXCLUDE_PATTERNS=(
    "--exclude=*.cfg" "--exclude=*.cfg.in"    # bootloader configs: no substitution
    "--exclude=*.desc" "--exclude=*.qml"      # Calamares branding: no substitution
    "--exclude=*.rc"                          # xfconf/panel dumps: no substitution
    "--exclude=*.desktop"
    "--exclude=*.list"
)
for d in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_PATTERNS+=("--exclude-dir=$(basename "${d}")")
done

# Also skip markdown files and known meta files
FILE_EXCLUDES=(
    "*.md"
    "CHANGELOG"
    "CONTRIBUTING"
    "LICENSE"
    "*.iso"
    "*.png"
    "*.svg"
    "*.jpg"
    "*.deb"
)
FILE_EXCLUDE_ARGS=()
for pat in "${FILE_EXCLUDES[@]}"; do
    FILE_EXCLUDE_ARGS+=("--exclude=${pat}")
done

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
log_section "ShopnoOS — Hardcoded Name Checker"
log_info "Repo root   : ${REPO_ROOT}"
log_info "Distro name : ${DISTRO_NAME}"
log_info "Codename    : ${DISTRO_CODENAME}"
log_info "Version     : ${DISTRO_VERSION}"
log_info "Website     : ${_website_domain}"
log_info "Strict mode : $( [[ "${STRICT}" -eq 1 ]] && echo "yes" || echo "no" )"
echo ""

TOTAL_VIOLATIONS=0
declare -A file_violations  # file -> count

for pattern in "${PATTERNS[@]}"; do
    # grep returns 1 if no match — that's fine
    while IFS= read -r match; do
        [[ -z "${match}" ]] && continue
        # match format: filepath:lineno:content
        file="${match%%:*}"
        rest="${match#*:}"
        lineno="${rest%%:*}"
        content="${rest#*:}"

	_is_header_title_line "${content}" && continue
	_has_ignore_marker "${content}" && continue

        file_violations["${file}"]=$(( ${file_violations["${file}"]:-0} + 1 ))
        (( TOTAL_VIOLATIONS++ )) || true

        if [[ "${QUIET}" -eq 0 ]]; then
            rel="${file#"${REPO_ROOT}"/}"
            echo -e "  ${RED}${rel}${RESET}:${DIM}${lineno}${RESET}"
            echo -e "    ${DIM}pattern : ${pattern}${RESET}"
            echo -e "    ${YELLOW}${content}${RESET}"
            echo ""
        fi
    done < <(
        grep -rn --include="*" \
            "${EXCLUDE_PATTERNS[@]}" \
            "${FILE_EXCLUDE_ARGS[@]}" \
            -E "${pattern}" \
            "${REPO_ROOT}" 2>/dev/null \
            || true
    )
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ "${TOTAL_VIOLATIONS}" -eq 0 ]]; then
    log_ok "No hardcoded distro names or URLs found."
    echo ""
    exit 0
fi

unique_files="${#file_violations[@]}"
log_error "${TOTAL_VIOLATIONS} violation(s) in ${unique_files} file(s)."
echo ""
echo -e "  ${RED}${BOLD}ACTION REQUIRED:${RESET} Replace hardcoded values with \${DISTRO_*} variables."
echo -e "  ${DIM}Source brand vars via: source scripts/lib/brand.sh${RESET}"
echo -e "  ${DIM}See: docs/branding-guide.md${RESET}"
echo ""
exit 1
