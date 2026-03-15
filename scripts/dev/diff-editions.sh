#!/usr/bin/env bash
# =============================================================================
# scripts/dev/diff-editions.sh
# ShopnoOS — Edition/Profile Package Set Comparator
#
# USAGE:
#   ./scripts/dev/diff-editions.sh <edition-a> <edition-b>
#   ./scripts/dev/diff-editions.sh --profile <p1> <p2>
#   ./scripts/dev/diff-editions.sh desktop pro
#   ./scripts/dev/diff-editions.sh --profile shopno-os-desktop-gnome shopno-os-pro-gnome
#
# OUTPUT:
#   A clear diff showing:
#   - Packages only in A
#   - Packages only in B
#   - Packages in both
#   - Summary counts
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
OPT_PROFILE_MODE=0
TARGET_A=""
TARGET_B=""

_usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") <edition-a> <edition-b>             Compare two editions
  $(basename "$0") --profile <profile-a> <profile-b>   Compare full profiles

Examples:
  $0 desktop pro
  $0 --profile shopno-os-desktop-gnome shopno-os-pro-gnome
EOF
    exit 1
}

[[ $# -eq 0 ]] && _usage

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile) OPT_PROFILE_MODE=1 ;;
        -h|--help) _usage ;;
        -*)        log_error "Unknown option: ${1}"; _usage ;;
        *)
            if [[ -z "${TARGET_A}" ]];   then TARGET_A="${1}"
            elif [[ -z "${TARGET_B}" ]]; then TARGET_B="${1}"
            else log_error "Too many arguments."; _usage; fi
            ;;
    esac
    shift
done

[[ -z "${TARGET_A}" || -z "${TARGET_B}" ]] && { log_error "Two targets required."; _usage; }

# ---------------------------------------------------------------------------
# Extract package list from an edition directory or full profile
# ---------------------------------------------------------------------------

# _pkgs_from_dir "dir" — extract all packages from *.list.chroot in a dir
_pkgs_from_dir() {
    local dir="${1}/package-lists"
    if [[ ! -d "${dir}" ]]; then
        log_error "No package-lists directory: ${dir}"
        exit 1
    fi
    grep -hEv '^\s*(#|$)' "${dir}"/*.list.chroot 2>/dev/null \
        | awk '{print $1}' \
        | sort -u
}

# _pkgs_from_profile "profile-name" — extract all packages for a full profile
_pkgs_from_profile() {
    local profile="${1}"
    # shellcheck source=../lib/profile.sh
    source "${LIB_DIR}/profile.sh"
    # shellcheck source=../lib/brand.sh
    source "${LIB_DIR}/brand.sh"
    load_profile "${profile}"

    local tmpfile
    tmpfile="$(mktemp)"
    while IFS= read -r list_file; do
        grep -hEv '^\s*(#|$)' "${list_file}" 2>/dev/null \
            | awk '{print $1}' >> "${tmpfile}" || true
    done < <(profile_package_lists)

    sort -u "${tmpfile}"
    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# Collect packages
# ---------------------------------------------------------------------------
TMP_A="$(mktemp)"
TMP_B="$(mktemp)"
trap 'rm -f "${TMP_A}" "${TMP_B}"' EXIT

if [[ "${OPT_PROFILE_MODE}" -eq 1 ]]; then
    log_step "Comparing profiles: ${TARGET_A}  vs  ${TARGET_B}"
    _pkgs_from_profile "${TARGET_A}" > "${TMP_A}"
    _pkgs_from_profile "${TARGET_B}" > "${TMP_B}"
    LABEL_A="profile:${TARGET_A}"
    LABEL_B="profile:${TARGET_B}"
else
    log_step "Comparing editions: ${TARGET_A}  vs  ${TARGET_B}"
    _pkgs_from_dir "${ABRAR_REPO_ROOT}/editions/${TARGET_A}" > "${TMP_A}"
    _pkgs_from_dir "${ABRAR_REPO_ROOT}/editions/${TARGET_B}" > "${TMP_B}"
    LABEL_A="edition:${TARGET_A}"
    LABEL_B="edition:${TARGET_B}"
fi

COUNT_A="$(wc -l < "${TMP_A}")"
COUNT_B="$(wc -l < "${TMP_B}")"

# ---------------------------------------------------------------------------
# Compute diff sets
# ---------------------------------------------------------------------------
TMP_ONLY_A="$(mktemp)"
TMP_ONLY_B="$(mktemp)"
TMP_COMMON="$(mktemp)"
trap 'rm -f "${TMP_A}" "${TMP_B}" "${TMP_ONLY_A}" "${TMP_ONLY_B}" "${TMP_COMMON}"' EXIT

comm -23 "${TMP_A}" "${TMP_B}" > "${TMP_ONLY_A}"
comm -13 "${TMP_A}" "${TMP_B}" > "${TMP_ONLY_B}"
comm -12 "${TMP_A}" "${TMP_B}" > "${TMP_COMMON}"

COUNT_ONLY_A="$(wc -l < "${TMP_ONLY_A}")"
COUNT_ONLY_B="$(wc -l < "${TMP_ONLY_B}")"
COUNT_COMMON="$(wc -l < "${TMP_COMMON}")"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

echo ""
echo -e "${CLR_BOLD}${CLR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
echo -e "${CLR_BOLD}  Package Diff: ${TARGET_A}  vs  ${TARGET_B}${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
echo ""

# Packages only in A
echo -e "${CLR_BOLD}${CLR_GREEN}Only in ${LABEL_A} (${COUNT_ONLY_A} packages):${CLR_RESET}"
if [[ "${COUNT_ONLY_A}" -eq 0 ]]; then
    echo "  (none)"
else
    while IFS= read -r pkg; do
        echo -e "  ${CLR_GREEN}+ ${pkg}${CLR_RESET}"
    done < "${TMP_ONLY_A}"
fi

echo ""

# Packages only in B
echo -e "${CLR_BOLD}${CLR_RED}Only in ${LABEL_B} (${COUNT_ONLY_B} packages):${CLR_RESET}"
if [[ "${COUNT_ONLY_B}" -eq 0 ]]; then
    echo "  (none)"
else
    while IFS= read -r pkg; do
        echo -e "  ${CLR_RED}+ ${pkg}${CLR_RESET}"
    done < "${TMP_ONLY_B}"
fi

echo ""

# Shared packages
echo -e "${CLR_BOLD}${CLR_DIM}Shared by both (${COUNT_COMMON} packages):${CLR_RESET}"
if [[ "${COUNT_COMMON}" -eq 0 ]]; then
    echo "  (none)"
else
    while IFS= read -r pkg; do
        echo -e "  ${CLR_DIM}= ${pkg}${CLR_RESET}"
    done < "${TMP_COMMON}"
fi

echo ""
echo -e "${CLR_BOLD}${CLR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
echo -e "${CLR_BOLD}Summary:${CLR_RESET}"
echo -e "  ${LABEL_A} total  : ${COUNT_A}"
echo -e "  ${LABEL_B} total  : ${COUNT_B}"
echo -e "  Only in A       : ${COUNT_ONLY_A}"
echo -e "  Only in B       : ${COUNT_ONLY_B}"
echo -e "  Shared          : ${COUNT_COMMON}"
echo -e "${CLR_BOLD}${CLR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}"
echo ""
