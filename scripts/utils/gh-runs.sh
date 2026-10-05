#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-runs.sh
# ShopnoOS - Workflow run status at a glance
#
# USAGE:
#   ./scripts/utils/gh-runs.sh [--workflow iso|container|lint|FILE|NAME]
#     [--limit N] [--branch B] [--event E] [--status S] [--jobs]
#     [--repo OWNER/REPO]
#
# PURPOSE:
#   One remembered command instead of half a dozen `gh run list` spellings.
#   Defaults to the 12 most recent runs across all three workflows
#   (Build ISO, Build Container, Lint) - the same `--limit 12` shape used
#   during Phase 4/5 triage. The table's ID column is the RUN_ID that
#   gh-run-details.sh takes; --jobs additionally lists each run's
#   per-leg job IDs for gh-run-details.sh --job.
#
# OPTIONS:
#   --workflow W   iso | container | lint (shorthand), a workflow file
#                  (build-iso.yml), or the full workflow name ("Build ISO").
#                  Default: all workflows.
#   --limit N      Maximum runs to show (default: 12)
#   --branch B     Filter by branch (e.g. dev)
#   --event E      Filter by event (pull_request, push, workflow_dispatch)
#   --status S     Filter by status (queued, in_progress, completed,
#                  success, failure, ... - see `gh run list --help`)
#   --jobs         Also list each run's job IDs + verdicts (one extra API
#                  call per run - keep --limit small, e.g. --limit 3).
#   --repo R       OWNER/REPO (default: current repo via `gh repo view`,
#                  fallback: fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help     Show this help
#
# PREREQUISITES:
#   gh (authenticated); jq only for --jobs.
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

WORKFLOW=""
LIMIT=12
BRANCH=""
EVENT=""
STATUS=""
OPT_JOBS=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --workflow) WORKFLOW="${2}"; shift 2 ;;
        --limit)    LIMIT="${2}"; shift 2 ;;
        --branch)   BRANCH="${2}"; shift 2 ;;
        --event)    EVENT="${2}"; shift 2 ;;
        --status)   STATUS="${2}"; shift 2 ;;
        --jobs)     OPT_JOBS=1; shift ;;
        --repo)     REPO="${2}"; shift 2 ;;
        -h|--help)  _usage 0 ;;
        -*)         log_error "Unknown option: ${1}"; _usage ;;
        *)          log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command gh

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

# Shorthands used in daily triage -> values `gh run list -w` accepts.
case "${WORKFLOW}" in
    ""|"all")        WORKFLOW="" ;;
    iso)             WORKFLOW="build-iso.yml" ;;
    container)       WORKFLOW="container-build.yml" ;;
    lint)            WORKFLOW="lint-packages.yml" ;;
esac

FILTER_ARGS=()
[[ -n "${WORKFLOW}" ]] && FILTER_ARGS+=(--workflow "${WORKFLOW}")
[[ -n "${BRANCH}" ]]   && FILTER_ARGS+=(--branch "${BRANCH}")
[[ -n "${EVENT}" ]]    && FILTER_ARGS+=(--event "${EVENT}")
[[ -n "${STATUS}" ]]   && FILTER_ARGS+=(--status "${STATUS}")

log_info "Repo: ${REPO} | workflow: ${WORKFLOW:-all} | limit: ${LIMIT}"
gh run list -R "${REPO}" --limit "${LIMIT}" "${FILTER_ARGS[@]}"

# --- Per-run job IDs for gh-run-details.sh ----------------------------------
if [[ "${OPT_JOBS}" -eq 1 ]]; then
    require_command jq
    echo ""
    log_step "Jobs (run ID -> gh-run-details.sh RUN_ID; job ID -> --job)"
    RUN_IDS="$(gh run list -R "${REPO}" --limit "${LIMIT}" "${FILTER_ARGS[@]}" \
        --json databaseId --jq '.[].databaseId')"
    [[ -n "${RUN_IDS}" ]] || { log_info "No runs matched - no jobs to list."; exit 0; }
    while IFS= read -r RUN_ID; do
        gh run view "${RUN_ID}" -R "${REPO}" \
            --json databaseId,workflowName,headBranch,jobs \
            -q '"Run \(.databaseId) (\(.workflowName), \(.headBranch)):",
                ((.jobs // [])[] | "  \(.databaseId)  \(.status)/\(if (.conclusion // "") == "" then "-" else .conclusion end)  \(.name)"),
                (if ((.jobs // []) | length) == 0 then "  (no jobs reported yet)" else empty end)' \
            || log_warn "Could not fetch jobs for run ${RUN_ID}."
    done <<< "${RUN_IDS}"
fi
