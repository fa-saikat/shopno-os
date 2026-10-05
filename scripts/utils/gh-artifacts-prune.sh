#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-artifacts-prune.sh
# ShopnoOS - Delete GitHub Actions artifacts safely (quota recovery)
#
# USAGE:
#   ./scripts/utils/gh-artifacts-prune.sh (--id ID | --expired |
#     --older-than DAYS | --all) [--yes] [--dry-run] [--repo OWNER/REPO]
#
# PURPOSE:
#   Artifact quota is a recurring cost: when it fills, every upload step
#   fails red with `CreateArtifact: quota has been hit` (issue #64) and
#   the only fix is deleting artifacts by hand. This script wraps the
#   hand-typed `gh api -X DELETE .../artifacts/<id>` loop with a scope
#   selector, a dry-run preview, and a confirmation prompt.
#
# OPTIONS:
#   --id ID          Delete one artifact by ID
#   --expired        Delete all expired artifacts only
#   --older-than N   Delete artifacts created more than N days ago
#                    (expired or not - GitHub keeps unexpired ones up
#                    to the retention limit, and they count as quota)
#   --all            Delete every artifact (quota reset button)
#   --yes            Skip the confirmation prompt (for automation)
#   --dry-run        Print what would be deleted, delete nothing
#   --repo R         OWNER/REPO (default: current repo, fallback
#                    fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help       Show this help
#
# SAFETY:
#   Exactly one scope flag is required. Without --yes the script lists
#   the victims and asks for confirmation. Deleted artifacts cannot be
#   restored - but CI artifacts are rebuildable by rerunning the
#   workflow, which is why this exists at all.
#
# PREREQUISITES:
#   gh (authenticated with delete scope), jq.
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

SCOPE=""
SCOPE_ARG=""
OPT_YES=0
OPT_DRY_RUN=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --id)         SCOPE="id";         SCOPE_ARG="${2}"; shift 2 ;;
        --expired)    SCOPE="expired";    shift ;;
        --older-than) SCOPE="older-than"; SCOPE_ARG="${2}"; shift 2 ;;
        --all)        SCOPE="all";        shift ;;
        --yes)        OPT_YES=1; shift ;;
        --dry-run)    OPT_DRY_RUN=1; shift ;;
        --repo)       REPO="${2}"; shift 2 ;;
        -h|--help)    _usage 0 ;;
        -*)           log_error "Unknown option: ${1}"; _usage ;;
        *)            log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

[[ -z "${SCOPE}" ]] && { log_error "A scope flag is required: --id, --expired, --older-than, or --all."; _usage; }
require_command gh jq

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

# --- Resolve the victim list to "ID<TAB>NAME<TAB>SIZE" lines -----------------
VICTIMS=""
case "${SCOPE}" in
    id)
        VICTIMS="$(gh api "repos/${REPO}/actions/artifacts/${SCOPE_ARG}" \
            -q '"\(.id)\t\(.name)\t\(.size_in_bytes)"' 2>/dev/null)" \
            || die "Artifact ${SCOPE_ARG} not found in ${REPO}."
        ;;
    expired)
        VICTIMS="$(gh api "repos/${REPO}/actions/artifacts" --paginate \
            -q '.artifacts[] | select(.expired == true) | "\(.id)\t\(.name)\t\(.size_in_bytes)"')"
        ;;
    older-than)
        [[ "${SCOPE_ARG}" =~ ^[0-9]+$ ]] || die "--older-than needs a number of days, got '${SCOPE_ARG}'."
        CUTOFF="$(date -u -d "${SCOPE_ARG} days ago" +%Y-%m-%dT%H:%M:%SZ)"
        VICTIMS="$(gh api "repos/${REPO}/actions/artifacts" --paginate \
            --jq ".artifacts[] | select(.created_at < \"${CUTOFF}\") | \"\\(.id)\\t\\(.name)\\t\\(.size_in_bytes)\"")"
        ;;
    all)
        VICTIMS="$(gh api "repos/${REPO}/actions/artifacts" --paginate \
            -q '.artifacts[] | "\(.id)\t\(.name)\t\(.size_in_bytes)"')"
        ;;
esac

if [[ -z "${VICTIMS}" ]]; then
    log_info "Nothing to delete for scope '${SCOPE}${SCOPE_ARG:+=${SCOPE_ARG}}'."
    exit 0
fi

COUNT="$(echo "${VICTIMS}" | wc -l)"
BYTES="$(echo "${VICTIMS}" | awk -F'\t' '{s+=$3} END {print s+0}')"
log_info "Scope '${SCOPE}${SCOPE_ARG:+=${SCOPE_ARG}}': ${COUNT} artifact(s), ~$(numfmt --to=iec "${BYTES}" 2>/dev/null || echo "${BYTES} bytes")"
echo "${VICTIMS}" | awk -F'\t' '{ printf "  %-14s %-40s %s bytes\n", $1, $2, $3 }'

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_info "Dry run - nothing deleted."
    exit 0
fi

if [[ "${OPT_YES}" -eq 0 ]]; then
    confirm "Delete these ${COUNT} artifact(s) from ${REPO}?" \
        || { log_info "Aborted - nothing deleted."; exit 0; }
fi

DELETED=0
FAILED=0
while IFS=$'\t' read -r ART_ID _ART_NAME _ART_SIZE; do
    if gh api -X DELETE "repos/${REPO}/actions/artifacts/${ART_ID}" --silent 2>/dev/null; then
        DELETED=$((DELETED + 1))
    else
        log_warn "Failed to delete artifact ${ART_ID}."
        FAILED=$((FAILED + 1))
    fi
done <<< "${VICTIMS}"

log_success "Deleted ${DELETED}/${COUNT} artifact(s)${FAILED:+ (${FAILED} failed)}."
[[ "${FAILED}" -eq 0 ]] || exit 1
