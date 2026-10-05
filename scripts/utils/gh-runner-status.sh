#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-runner-status.sh
# ShopnoOS - Self-hosted runner status via the GitHub API
#
# USAGE:
#   ./scripts/utils/gh-runner-status.sh [--json] [--new-token]
#     [--repo OWNER/REPO]
#
# PURPOSE:
#   Answers "is shopno-iso-builder online, and is it busy" without opening
#   repo Settings or remembering the runners API path. Also shows what is
#   currently queued/in-progress so a `busy: true` can be matched to a run.
#   --new-token mints a fresh runner registration token (1h expiry) for
#   `terraform apply` rebirths - the exact command from
#   infra/terraform/README.md, kept here so it stays findable.
#
# OPTIONS:
#   --json        Raw runner JSON (for scripting) instead of the table
#   --new-token   Mint and print a registration token, then exit. The
#                 token is short-lived and never written to disk or git -
#                 pass it as TF_VAR_github_token on the same terminal.
#   --repo R      OWNER/REPO (default: current repo, fallback
#                 fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help    Show this help
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

OPT_JSON=0
OPT_NEW_TOKEN=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --json)      OPT_JSON=1; shift ;;
        --new-token) OPT_NEW_TOKEN=1; shift ;;
        --repo)      REPO="${2}"; shift 2 ;;
        -h|--help)   _usage 0 ;;
        -*)          log_error "Unknown option: ${1}"; _usage ;;
        *)           log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command gh jq

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

if [[ "${OPT_NEW_TOKEN}" -eq 1 ]]; then
    log_warn "Short-lived token - use immediately as TF_VAR_github_token; never commit it."
    gh api --method POST "repos/${REPO}/actions/runners/registration-token" --jq '.token'
    exit 0
fi

RUNNERS_JSON="$(gh api "repos/${REPO}/actions/runners")"

if [[ "${OPT_JSON}" -eq 1 ]]; then
    echo "${RUNNERS_JSON}" | jq '.runners'
    exit 0
fi

log_step "Runners on ${REPO}"
echo "${RUNNERS_JSON}" \
    | jq -r '.runners[] | "\(.name)\t\(.status)\tbusy=\(.busy)\tlabels=[\([.labels[].name] | join(","))]"' \
    | awk -F'\t' '{ printf "%-22s %-8s %-11s %s\n", $1, $2, $3, $4 }'

# Correlate `busy: true` with actual work: queued/in_progress runs right now.
ACTIVE="$(gh run list -R "${REPO}" --limit 20 --json databaseId,workflowName,headBranch,status \
    --jq '.[] | select(.status == "queued" or .status == "in_progress") | "\(.status) \(.workflowName) \(.headBranch) id=\(.databaseId)"' 2>/dev/null || true)"
if [[ -n "${ACTIVE}" ]]; then
    echo ""
    log_step "Active runs (why a runner may be busy)"
    echo "${ACTIVE}"
else
    echo ""
    log_info "No queued or in-progress runs - a busy runner here would be worth investigating."
fi
