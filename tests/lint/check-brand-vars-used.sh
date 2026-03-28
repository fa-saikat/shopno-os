#!/usr/bin/env bash
# =============================================================================
# tests/lint/check-brand-vars-used.sh
# ShopnoOS — Lint: Brand Variable Usage Completeness
#
# PURPOSE:
#   Verify that every variable declared in brand/identity/*.env is actually
#   referenced somewhere in the build system (scripts/, base/hooks/,
#   editions/, flavors/, tools/).
#
#   The inverse is also checked: if a script uses $DISTRO_* or $BRAND_*
#   but does NOT source brand.sh (directly or via common.sh), flag it.
#
# TWO CHECKS:
#   1. DECLARED BUT NEVER USED  — brand vars defined but not referenced anywhere
#   2. USED BUT NOT SOURCED     — scripts that reference DISTRO_* without
#                                 sourcing scripts/lib/brand.sh or common.sh
#
# EXIT CODES:
#   0 — all checks pass
#   1 — violations found
#
# USAGE:
#   ./tests/lint/check-brand-vars-used.sh [--repo-root <path>]
#
# FLAGS:
#   --repo-root <path>   Override repo root detection
#   --quiet              Summary only
#   --color / --no-color
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QUIET=0
COLOR="auto"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --repo-root) REPO_ROOT="${2}"; shift 2 ;;
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
log_warn()    { echo -e "  ${YELLOW}[warn]${RESET}  ${*}"; }
log_info()    { echo -e "  ${DIM}[info]${RESET}  ${*}"; }
log_section() { echo -e "\n${BOLD}${*}${RESET}"; }

# ---------------------------------------------------------------------------
# Step 1: Collect all declared brand variables from brand/identity/*.env
# ---------------------------------------------------------------------------
BRAND_DIR="${REPO_ROOT}/brand/identity"

declare -a DECLARED_VARS=()

_collect_declared_vars() {
    if [[ ! -d "${BRAND_DIR}" ]]; then
        log_warn "brand/identity/ directory not found — skipping declared-var check."
        return 0
    fi

    while IFS= read -r env_file; do
        while IFS= read -r line; do
            # Skip blanks and comments
            [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            # Extract variable name: everything before the first =
            var_name="${line%%=*}"
            # Must be a valid shell identifier
            if [[ "${var_name}" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                DECLARED_VARS+=("${var_name}")
            fi
        done < "${env_file}"
    done < <(find "${BRAND_DIR}" -name "*.env" | sort)
}

_collect_declared_vars

# ---------------------------------------------------------------------------
# Step 2: Scan the build tree for usages of $VAR or ${VAR}
# Directories to scan for usage:
# ---------------------------------------------------------------------------
USAGE_SCAN_DIRS=(
    "${REPO_ROOT}/scripts"
    "${REPO_ROOT}/base/hooks"
    "${REPO_ROOT}/editions"
    "${REPO_ROOT}/flavors"
    "${REPO_ROOT}/hardware"
    "${REPO_ROOT}/tools"
    "${REPO_ROOT}/profiles"
    "${REPO_ROOT}/base/config"
)

EXCLUDE_FROM_USAGE=(
    "${REPO_ROOT}/.git"
    "${REPO_ROOT}/brand"
    "${REPO_ROOT}/build"
    "${REPO_ROOT}/tests"
    "${REPO_ROOT}/docs"
)

EXCLUDE_DIR_ARGS=()
for d in "${EXCLUDE_FROM_USAGE[@]}"; do
    EXCLUDE_DIR_ARGS+=("--exclude-dir=$(basename "${d}")")
done

_var_is_used() {
    local var="${1}"
    # Match $VAR or ${VAR}
    local pattern='\$\{?'"${var}"'\}?'
    grep -qrE "${pattern}" \
        "${EXCLUDE_DIR_ARGS[@]}" \
        --exclude="*.md" \
        --exclude="*.iso" \
        --exclude="*.png" \
        "${USAGE_SCAN_DIRS[@]}" 2>/dev/null \
        || return 1
}

# ---------------------------------------------------------------------------
# Step 3: Find scripts that use DISTRO_* / BRAND_* but don't source brand.sh
# ---------------------------------------------------------------------------
BRAND_SH_REF_PATTERNS=(
    "brand\.sh"
    "common\.sh"
    "source.*lib/"
    "\. .*lib/"
)

_file_sources_brand() {
    local file="${1}"

    # Chroot/binary hooks run inside the chroot and cannot access host scripts.
    # They receive brand vars via the injected build-vars.env — exempt them.
    if [[ "${file}" == *.hook.chroot || "${file}" == *.hook.binary ]]; then
        return 0
    fi

    for pat in "${BRAND_SH_REF_PATTERNS[@]}"; do
        grep -qE "${pat}" "${file}" 2>/dev/null && return 0
    done
    return 1
}

_file_uses_brand_vars() {
    local file="${1}"
    grep -qE '\$\{?(DISTRO_|BRAND_)[A-Z_]+\}?' "${file}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Run checks
# ---------------------------------------------------------------------------
log_section "ShopnoOS — Brand Variable Usage Checker"
log_info "Repo root     : ${REPO_ROOT}"
log_info "Declared vars : ${#DECLARED_VARS[@]} from brand/identity/*.env"
echo ""

FAIL=0

# --- Check 1: Declared but never used ---
log_section "Check 1/2: Declared-but-never-used brand variables"

UNUSED_COUNT=0
if [[ ${#DECLARED_VARS[@]} -eq 0 ]]; then
    log_warn "No brand variables found in brand/identity/ — skipping."
else
    for var in "${DECLARED_VARS[@]}"; do
        if ! _var_is_used "${var}"; then
            (( UNUSED_COUNT++ )) || true
            if [[ "${QUIET}" -eq 0 ]]; then
                log_warn "UNUSED: ${BOLD}${var}${RESET}${YELLOW} — declared in brand/identity/ but never referenced in build scripts${RESET}"
            fi
        fi
    done

    if [[ "${UNUSED_COUNT}" -eq 0 ]]; then
        log_ok "All ${#DECLARED_VARS[@]} brand variable(s) are referenced in the build tree."
    else
        log_warn "${UNUSED_COUNT} declared variable(s) appear to be unused."
        echo -e "  ${DIM}These may be intentional (future use) or stale. Review before removing.${RESET}"
        # Unused vars are a warning, not a hard failure — they don't break builds
    fi
fi

echo ""

# --- Check 2: Scripts using brand vars without sourcing brand.sh ---
log_section "Check 2/2: Scripts using DISTRO_* without sourcing brand.sh"

UNSOURCED_COUNT=0

for scan_dir in "${USAGE_SCAN_DIRS[@]}"; do
    [[ ! -d "${scan_dir}" ]] && continue
    while IFS= read -r sh_file; do
        if _file_uses_brand_vars "${sh_file}" && ! _file_sources_brand "${sh_file}"; then
            (( UNSOURCED_COUNT++ )) || true
            (( FAIL++ )) || true
            if [[ "${QUIET}" -eq 0 ]]; then
                rel="${sh_file#"${REPO_ROOT}"/}"
                log_error "UNSOURCED: ${RED}${rel}${RESET}"
                echo -e "    ${DIM}Uses \$DISTRO_* or \$BRAND_* but does not source brand.sh or common.sh${RESET}"
                # Show the offending lines
                grep -nE '\$\{?(DISTRO_|BRAND_)[A-Z_]+\}?' "${sh_file}" \
                    | head -5 \
                    | while IFS= read -r match_line; do
                        echo -e "    ${DIM}${match_line}${RESET}"
                    done
                echo ""
            fi
        fi
    done < <(find "${scan_dir}" -type f \( -name "*.sh" -o -name "*.hook.chroot" -o -name "*.hook.binary" \) | sort)
done

if [[ "${UNSOURCED_COUNT}" -eq 0 ]]; then
    log_ok "All scripts that reference brand variables properly source brand.sh."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "${FAIL}" -gt 0 ]]; then
    log_error "${FAIL} violation(s) require attention."
    echo -e "  ${DIM}All build scripts must: source \"\$(dirname \"\$0\")/../lib/brand.sh\"${RESET}"
    echo -e "  ${DIM}See: scripts/lib/brand.sh and scripts/lib/common.sh${RESET}"
    echo ""
    exit 1
fi

log_ok "Brand variable checks passed."
echo ""
exit 0
