#!/usr/bin/env bash
# =============================================================================
# tests/lint/check-duplicate-packages.sh
# ShopnoOS — Lint: Duplicate Package Detection
#
# PURPOSE:
#   Enforce the Golden Rule *within a single layer instance*: a package must
#   not be declared twice inside the same base/, the same edition/<n>/, the
#   same flavor/<n>/, or the same hardware/<n>/.
#
#   Duplicate package NAMES across DIFFERENT layer instances of the same
#   type (e.g. editions/desktop/ vs editions/gaming/, or flavors/xfce/ vs
#   flavors/gnome/) are NOT flagged. A profile only ever activates one
#   edition, one flavor, and one hardware layer at a time (see
#   scripts/lib/profile.sh) — two editions declaring the same package is
#   not a collision, it's two independent, mutually-exclusive selections
#   that happen to overlap. See docs/package-ownership.md
#   § "Cross-Layer Package Sharing" for the full policy.
#
#   Duplication between an active edition and its paired flavor is still
#   checked, but per-profile — that lives in scripts/dev/lint-packages.sh
#   (Check 5), not here.
#
# SCOPES CHECKED (independently — never against each other):
#   - base                    (all *.list.chroot under base/, as one group)
#   - edition:<name>          (all *.list.chroot under editions/<name>/)
#   - flavor:<name>           (all *.list.chroot under flavors/<name>/)
#   - hardware:<name>         (all *.list.chroot under hardware/<name>/)
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

# _scope_for_path "abs_path"
# Prints the scope key a given list file belongs to:
#   base
#   edition:<name>
#   flavor:<name>
#   hardware:<name>
#   unknown:<rel-path>   (defensive fallback — should never happen)
_scope_for_path() {
    local path="${1}"
    local rel="${path#"${REPO_ROOT}"/}"

    case "${rel}" in
        base/*)
            echo "base"
            ;;
        editions/*)
            local rest="${rel#editions/}"
            echo "edition:${rest%%/*}"
            ;;
        flavors/*)
            local rest="${rel#flavors/}"
            echo "flavor:${rest%%/*}"
            ;;
        hardware/*)
            local rest="${rel#hardware/}"
            echo "hardware:${rest%%/*}"
            ;;
        *)
            echo "unknown:${rel}"
            ;;
    esac
}

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
log_info "Scope     : per-layer-instance (base / each edition / each flavor / each hardware)"

# ---------------------------------------------------------------------------
# Build a map: "scope||package_name" → list of files it appears in
# ---------------------------------------------------------------------------
declare -A pkg_files   # "scope||pkg" -> space-separated list of file paths
declare -A pkg_count   # "scope||pkg" -> count
declare -A scope_seen  # scope -> 1 (summary only)

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
    rel="${list_file#"${REPO_ROOT}"/}"
    scope="$(_scope_for_path "${list_file}")"
    scope_seen["${scope}"]=1

    while IFS= read -r pkg; do
        [[ -z "${pkg}" ]] && continue
        key="${scope}||${pkg}"
        if [[ -n "${pkg_files[${key}]+_}" ]]; then
            pkg_files["${key}"]+=" ${rel}"
            (( pkg_count["${key}"]++ )) || true
        else
            pkg_files["${key}"]="${rel}"
            pkg_count["${key}"]=1
        fi
    done < <(_strip_comments "${list_file}")
done

log_info "Layer instances scanned: ${#scope_seen[@]}"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
DUPLICATES=()
for key in $(echo "${!pkg_count[@]}" | tr ' ' '\n' | sort); do
    if [[ ${pkg_count["${key}"]} -gt 1 ]]; then
        DUPLICATES+=("${key}")
    fi
done

echo ""
if [[ ${#DUPLICATES[@]} -eq 0 ]]; then
    log_ok "No duplicate packages found within any single layer instance (${#scope_seen[@]} scopes, ${#LIST_FILES[@]} list files)."
    echo ""
    exit 0
fi

log_error "${#DUPLICATES[@]} duplicate package(s) detected within a single layer instance:"
echo ""

if [[ "${QUIET}" -eq 0 ]]; then
    for key in "${DUPLICATES[@]}"; do
        scope="${key%%||*}"
        pkg="${key#*||}"
        echo -e "  ${RED}${BOLD}${pkg}${RESET}  ${DIM}(scope: ${scope})${RESET}"
        for f in ${pkg_files["${key}"]}; do
            echo -e "    ${DIM}→ ${f}${RESET}"
        done
        echo ""
    done
fi

echo -e "  ${RED}${BOLD}ACTION REQUIRED:${RESET} Within the same edition/flavor/hardware layer (or"
echo -e "  within base/), a package must live in exactly one list file. Packages repeated"
echo -e "  across DIFFERENT editions or DIFFERENT flavors (e.g. editions/desktop/ and"
echo -e "  editions/gaming/) are allowed and are not reported here."
echo -e "  ${DIM}See: docs/package-ownership.md § Cross-Layer Package Sharing${RESET}"
echo ""
exit 1
