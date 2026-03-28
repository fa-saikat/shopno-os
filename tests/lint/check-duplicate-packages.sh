#!/usr/bin/env bash
# =============================================================================
# tests/lint/check-duplicate-packages.sh
# ShopnoOS — Lint: Duplicate Package Detection
#
# PURPOSE:
#   Enforce the Golden Rule: a package lives in exactly ONE place.
#   Scans all *.list.chroot and *.list.binary files across base/, editions/,
#   flavors/, and hardware/, then reports any package name that appears in
#   more than one file.
#
# EXIT CODES:
#   0 — no duplicates found
#   1 — one or more duplicates detected (or usage error)
#
# USAGE:
#   ./tests/lint/check-duplicate-packages.sh [--repo-root <path>]
#
# FLAGS:
#   --repo-root <path>   Override auto-detected repo root (default: two dirs up
#                        from this script's location)
#   --quiet              Suppress per-package detail; print summary only
#   --color              Force ANSI color even when not a TTY
#   --no-color           Disable ANSI color
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QUIET=0
COLOR="auto"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --repo-root)  REPO_ROOT="${2}"; shift 2 ;;
        --quiet)      QUIET=1; shift ;;
        --color)      COLOR="always"; shift ;;
        --no-color)   COLOR="never"; shift ;;
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

log_info()    { echo -e "  ${DIM}[info]${RESET}  ${*}"; }
log_ok()      { echo -e "  ${GREEN}[ok]${RESET}    ${*}"; }
log_warn()    { echo -e "  ${YELLOW}[warn]${RESET}  ${*}"; }
log_error()   { echo -e "  ${RED}[FAIL]${RESET}  ${*}" >&2; }
log_section() { echo -e "\n${BOLD}${*}${RESET}"; }

# ---------------------------------------------------------------------------
# Collect all package list files
# ---------------------------------------------------------------------------
SEARCH_DIRS=(
    "${REPO_ROOT}/base"
    "${REPO_ROOT}/editions"
    "${REPO_ROOT}/flavors"
    "${REPO_ROOT}/hardware"
)

LIST_FILES=()
for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
        while IFS= read -r f; do
            LIST_FILES+=("${f}")
        done < <(find "${dir}" -type f \( -name "*.list.chroot" -o -name "*.list.binary" \) | sort)
    fi
done

if [[ ${#LIST_FILES[@]} -eq 0 ]]; then
    log_warn "No package list files found under ${REPO_ROOT}. Nothing to check."
    exit 0
fi

log_section "ShopnoOS — Duplicate Package Checker"
log_info "Repo root : ${REPO_ROOT}"
log_info "List files: ${#LIST_FILES[@]} found"

# ---------------------------------------------------------------------------
# Build a map: package_name → list of files it appears in
# ---------------------------------------------------------------------------
# Use a temp dir for associative-array simulation compatible with bash 4+
declare -A pkg_files   # pkg_name -> space-separated list of file paths
declare -A pkg_count   # pkg_name -> count

_strip_comments() {
    # Remove blank lines, comment lines, and inline comments.
    # Also normalise: lowercase, trim whitespace, strip version constraints
    # e.g. "curl (>= 7.68)" → "curl"
    grep -v '^\s*#' "${1}" \
        | grep -v '^\s*$' \
        | sed 's/#.*//' \
        | sed 's/[[:space:]]*([^)]*)//' \
        | tr '[:upper:]' '[:lower:]' \
        | awk '{print $1}' \
        | sort -u
}

for list_file in "${LIST_FILES[@]}"; do
    # path relative to repo root for cleaner output
    rel="${list_file#"${REPO_ROOT}"/}"

    while IFS= read -r pkg; do
        [[ -z "${pkg}" ]] && continue
        if [[ -n "${pkg_files[${pkg}]+_}" ]]; then
            pkg_files["${pkg}"]+=" ${rel}"
            (( pkg_count["${pkg}"]++ )) || true
        else
            pkg_files["${pkg}"]="${rel}"
            pkg_count["${pkg}"]=1
        fi
    done < <(_strip_comments "${list_file}")
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
DUPLICATES=()
for pkg in $(echo "${!pkg_count[@]}" | tr ' ' '\n' | sort); do
    if [[ ${pkg_count["${pkg}"]} -gt 1 ]]; then
        DUPLICATES+=("${pkg}")
    fi
done

echo ""
if [[ ${#DUPLICATES[@]} -eq 0 ]]; then
    log_ok "No duplicate packages found across ${#LIST_FILES[@]} list files."
    echo ""
    exit 0
fi

log_error "${#DUPLICATES[@]} duplicate package(s) detected:"
echo ""

if [[ "${QUIET}" -eq 0 ]]; then
    for pkg in "${DUPLICATES[@]}"; do
        echo -e "  ${RED}${BOLD}${pkg}${RESET}"
        # Print each file on its own indented line
        for f in ${pkg_files["${pkg}"]}; do
            echo -e "    ${DIM}→ ${f}${RESET}"
        done
        echo ""
    done
fi

echo -e "  ${RED}${BOLD}ACTION REQUIRED:${RESET} Each package must live in exactly one list file."
echo -e "  ${DIM}See: docs/package-ownership.md${RESET}"
echo ""
exit 1
