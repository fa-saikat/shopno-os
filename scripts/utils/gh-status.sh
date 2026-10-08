#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-status.sh
# ShopnoOS - Is GitHub itself the reason runs are stuck?
#
# USAGE:
#   ./scripts/utils/gh-status.sh [--all]
#
# PURPOSE:
#   Before blaming the self-hosted runner or the workflow YAML for queued
#   / stuck runs, check GitHub's own status. Queries the public status API
#   (no auth needed) and reports the overall indicator, the three
#   components this project depends on (Actions = runs, Packages = GHCR
#   pushes, API Requests = every `gh` command in scripts/utils/), and any
#   unresolved incidents with their latest update.
#
# OPTIONS:
#   --all        Show every component, not just Actions/Packages/API
#   -h, --help   Show this help
#
# EXIT CODES:
#   0 - Actions, Packages and API Requests all operational
#   1 - any of the three degraded (composable: gh-status.sh &&
#       gh-dispatch.sh ...), or the status API itself unreachable
#
# PREREQUISITES:
#   curl, jq. No authentication required.
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

OPT_ALL=0

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --all)   OPT_ALL=1; shift ;;
        -h|--help) _usage 0 ;;
        -*)      log_error "Unknown option: ${1}"; _usage ;;
        *)       log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command curl jq

STATUS_URL="https://www.githubstatus.com/api/v2/summary.json"
SUMMARY="$(curl -sL --max-time 20 "${STATUS_URL}")" \
    || die "Could not reach ${STATUS_URL} - check network before blaming GitHub."
[[ -n "${SUMMARY}" ]] && echo "${SUMMARY}" | jq -e '.status' >/dev/null \
    || die "Unexpected response from the status API."

INDICATOR="$(echo "${SUMMARY}" | jq -r '.status.indicator')"
DESCRIPTION="$(echo "${SUMMARY}" | jq -r '.status.description')"

log_step "GitHub status: ${DESCRIPTION} [${INDICATOR}] (full page: https://www.githubstatus.com)"

if [[ "${OPT_ALL}" -eq 1 ]]; then
    echo "${SUMMARY}" | jq -r '.components[] | "\(.status)\t\(.name)"' \
        | awk -F'\t' '{ printf "  %-22s %s\n", $2, $1 }'
else
    echo "${SUMMARY}" | jq -r '.components[]
        | select(.name == "Actions" or .name == "Packages" or .name == "API Requests")
        | "\(.status)\t\(.name)"' \
        | awk -F'\t' '{ printf "  %-22s %s\n", $2, $1 }'
fi

# Unresolved incidents (summary.json only carries those) with latest update.
INCIDENT_COUNT="$(echo "${SUMMARY}" | jq '[.incidents[]] | length')"
if [[ "${INCIDENT_COUNT}" -gt 0 ]]; then
    echo ""
    log_step "${INCIDENT_COUNT} unresolved incident(s)"
    echo "${SUMMARY}" | jq -r '.incidents[]
        | "--- \(.name) [impact=\(.impact // "?"), status=\(.status)]\n    \(.shortlink // "")\n    latest: \((.incident_updates[0].body // "no updates yet") | .[0:400])"'
fi

# Verdict over exactly the three components this repo's automation needs.
BAD="$(echo "${SUMMARY}" | jq -r '[.components[]
    | select(.name == "Actions" or .name == "Packages" or .name == "API Requests")
    | select(.status != "operational") | .name] | join(", ")')"
if [[ -n "${BAD}" ]]; then
    echo ""
    log_error "Degraded: ${BAD}."
    log_error "Queued/stuck runs are likely GitHub-side - confirm with gh-runs.sh --status queued before touching the runner."
    exit 1
fi

log_success "Actions, Packages and API Requests all operational - stuck runs are NOT GitHub-side."
