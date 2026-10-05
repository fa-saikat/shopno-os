#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-quota.sh
# ShopnoOS - Artifact/cache/package storage vs the GitHub quota
#
# USAGE:
#   ./scripts/utils/gh-quota.sh [--repo OWNER/REPO] [--plan free|pro|team|
#     enterprise] [--quota BYTES]
#
# PURPOSE:
#   Answers "how full is the artifact quota" - the number behind
#   `CreateArtifact: quota has been hit` (issue #64). GitHub retired the
#   old per-user billing endpoints (HTTP 410), so there is no single
#   "remaining" API anymore; this script sums the measurable components
#   instead: Actions artifacts + Actions caches in every repo owned by
#   the authenticated user, plus container package counts.
#
#   Quota model (docs, verified 2026-10-05): the plan's allowance is ONE
#   shared pool for artifacts + caches + packages - Free 500 MB, Pro
#   1 GB, Team 2 GB, Enterprise 50 GB. Caches additionally cap at 10 GB
#   per repository. Enforcement lags reality: GitHub recalculates usage
#   every 6-12 hours, so uploads keep failing for hours AFTER a prune -
#   that lag, not a failed delete, is usually why a "quota probe" right
#   after pruning still looks exhausted.
#
# OPTIONS:
#   --repo R       Single repo for a fast check (default: all repos of
#                  the authenticated user - slower, ~2 API calls each)
#   --plan P       Your plan: free (500 MB, default), pro (1 GB),
#                  team (2 GB), enterprise (50 GB). GH_PLAN env honored.
#   --quota B      Explicit quota in bytes (overrides --plan).
#                  GH_QUOTA_BYTES env honored.
#   -h, --help     Show this help
#
# EXIT CODES:
#   0 - report printed (even when over quota; this reports, not gates)
#
# PREREQUISITES:
#   gh (authenticated), jq.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

_usage() {
    sed -n '2,/^# ====/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-1}"
}

_human() {
    numfmt --to=iec "$1" 2>/dev/null || echo "$1 B"
}

REPO=""
PLAN="${GH_PLAN:-free}"
QUOTA="${GH_QUOTA_BYTES:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --repo)  REPO="${2}"; shift 2 ;;
        --plan)  PLAN="${2}"; shift 2 ;;
        --quota) QUOTA="${2}"; shift 2 ;;
        -h|--help) _usage 0 ;;
        -*)      log_error "Unknown option: ${1}"; _usage ;;
        *)       log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command gh jq

if [[ -z "${QUOTA}" ]]; then
    case "${PLAN}" in
        free)       QUOTA=524288000 ;;      # 500 MB
        pro)        QUOTA=1073741824 ;;     # 1 GB
        team)       QUOTA=2147483648 ;;     # 2 GB
        enterprise) QUOTA=53687091200 ;;    # 50 GB
        *)          die "Unknown plan '${PLAN}' - use free|pro|team|enterprise or --quota BYTES." ;;
    esac
fi

if [[ -n "${REPO}" ]]; then
    REPOS="${REPO}"
else
    log_info "Listing repos of the authenticated user ..."
    REPOS="$(gh repo list --json nameWithOwner --limit 1000 --jq '.[].nameWithOwner')"
    [[ -n "${REPOS}" ]] || die "No repos found for the authenticated user."
fi

TOTAL_ART_BYTES=0
TOTAL_ART_COUNT=0
TOTAL_CACHE_BYTES=0

echo ""
printf "%-42s %8s %12s %12s\n" "REPO" "ARTIFACTS" "ARTIFACTS" "CACHES"
printf "%-42s %8s %12s %12s\n" "----" "---------" "---------" "------"

while IFS= read -r R; do
    [[ -n "${R}" ]] || continue
    ART_JSON="$(gh api "repos/${R}/actions/artifacts?per_page=100" \
        --jq '{n: (.total_count // 0), b: ([.artifacts[].size_in_bytes] | add // 0)}' 2>/dev/null \
        || echo '{"n":0,"b":0}')"
    # NOTE: per_page=100 without --paginate undercounts repos with 100+
    # artifacts; the totals below are a floor, never a ceiling. Add
    # --paginate here if a repo ever hoards that many (slow but exact).
    A_N="$(echo "${ART_JSON}" | jq -r .n)"
    A_B="$(echo "${ART_JSON}" | jq -r .b)"
    CACHE_JSON="$(gh api "repos/${R}/actions/cache/usage" \
        --jq '{b: (.active_caches_size_in_bytes // 0), n: (.active_caches_count // 0)}' 2>/dev/null \
        || echo '{"b":0,"n":0}')"
    C_B="$(echo "${CACHE_JSON}" | jq -r .b)"
    C_N="$(echo "${CACHE_JSON}" | jq -r .n)"
    TOTAL_ART_BYTES=$((TOTAL_ART_BYTES + A_B))
    TOTAL_ART_COUNT=$((TOTAL_ART_COUNT + A_N))
    TOTAL_CACHE_BYTES=$((TOTAL_CACHE_BYTES + C_B))
    if [[ "${A_B}" -gt 0 || "${C_B}" -gt 0 ]]; then
        printf "%-42s %8d %12s %12s\n" "${R}" "${A_N}" "$(_human "${A_B}")" "$(_human "${C_B}")${C_N:+ (${C_N})}"
    fi
done <<< "${REPOS}"

echo ""
log_step "Storage vs quota (plan: ${PLAN}, quota: $(_human "${QUOTA}"))"
log_info "Artifacts: ${TOTAL_ART_COUNT} file(s), $(_human "${TOTAL_ART_BYTES}") across repos above"
log_info "Caches:    $(_human "${TOTAL_CACHE_BYTES}") (separate 10 GB/repo allowance)"

# Packages share the pool but expose no byte sizes via API - report counts.
PKG_NAMES="$(gh api '/user/packages?package_type=container' --jq '.[].name' 2>/dev/null || true)"
if [[ -n "${PKG_NAMES}" ]]; then
    while IFS= read -r P; do
        V_N="$(gh api "/user/packages/container/${P}/versions?per_page=100" --jq 'length' 2>/dev/null || echo "?")"
        log_info "Package:   ${P} - ${V_N} version(s) (bytes not exposed by API; each image ~ last tarball size)"
    done <<< "${PKG_NAMES}"
else
    log_info "Packages:  none (container namespace empty)"
fi

if [[ "${TOTAL_ART_BYTES}" -ge "${QUOTA}" ]]; then
    TIMES="$(awk "BEGIN { printf \"%.1f\", ${TOTAL_ART_BYTES} / ${QUOTA} }")"
    log_error "OVER QUOTA: artifacts alone are ~${TIMES}x the $(_human "${QUOTA}") pool - uploads fail until pruning + the 6-12h recalculation."
    log_error "Recover: ./scripts/utils/gh-artifacts-prune.sh --older-than 1 --dry-run (then without --dry-run), then WAIT before re-probing."
else
    FREE=$((QUOTA - TOTAL_ART_BYTES))
    log_success "Under quota: $(_human "${FREE}") of $(_human "${QUOTA}") still free for artifacts+packages."
fi
