#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-run-details.sh
# ShopnoOS - Job-level details for one workflow run
#
# USAGE:
#   ./scripts/utils/gh-run-details.sh RUN_ID [--log] [--log-failed]
#     [--job JOB_ID] [--web] [--repo OWNER/REPO]
#
# PURPOSE:
#   Answers "what actually happened in that run" without reconstructing
#   the `gh run view` / `gh api .../jobs` / log-grep pipeline by hand.
#   Prints run metadata, per-job verdicts, the run's artifacts, and -
#   with --log - the boot-gate verdict lines this project actually
#   triages on (package/boot PASSED/FAILED, KVM line, CreateArtifact
#   quota errors, ##[error] markers).
#
# OPTIONS:
#   RUN_ID         Workflow run database ID (first column of gh-runs.sh)
#   --log          Fetch the full log and print verdict-relevant lines
#   --log-failed   Same, but only failed steps (cheaper on huge logs)
#   --job JOB_ID   Restrict --log to one job (see `gh run view --job`)
#   --web          Open the run in the browser instead of printing
#   --repo R       OWNER/REPO (default: current repo, fallback
#                  fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help     Show this help
#
# EXIT CODES:
#   0 - details printed (even for a failed run; this reports, not gates)
#   1 - run not found / API error
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

RUN_ID=""
OPT_LOG=0
OPT_LOG_FAILED=0
OPT_JOB=""
OPT_WEB=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --log)        OPT_LOG=1; shift ;;
        --log-failed) OPT_LOG_FAILED=1; shift ;;
        --job)        OPT_JOB="${2}"; shift 2 ;;
        --web)        OPT_WEB=1; shift ;;
        --repo)       REPO="${2}"; shift 2 ;;
        -h|--help)    _usage 0 ;;
        -*)           log_error "Unknown option: ${1}"; _usage ;;
        *)            if [[ -z "${RUN_ID}" ]]; then RUN_ID="${1}"; shift;
                      else log_error "Unexpected positional argument: ${1}"; _usage; fi ;;
    esac
done

[[ -z "${RUN_ID}" ]] && { log_error "RUN_ID is required."; _usage; }
require_command gh jq

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

if [[ "${OPT_WEB}" -eq 1 ]]; then
    gh run view "${RUN_ID}" -R "${REPO}" --web
    exit 0
fi

# --- Run metadata + per-job verdicts ---------------------------------------
log_step "Run ${RUN_ID} (${REPO})"
gh run view "${RUN_ID}" -R "${REPO}" \
    --json databaseId,workflowName,headBranch,event,status,conclusion,createdAt,updatedAt,url \
    -q '"\(.workflowName) | \(.headBranch) | \(.event) | \(.status)/\(if (.conclusion // "") == "" then "-" else .conclusion end) | created \(.createdAt)\n\(.url)"'

echo ""
log_step "Jobs (job ID -> --job)"
gh run view "${RUN_ID}" -R "${REPO}" --json jobs \
    -q '.jobs[] | "\(.databaseId)  \(.status)/\(if (.conclusion // "") == "" then "-" else .conclusion end)  \(.name)"'

# --- Artifacts attached to this run -----------------------------------------
echo ""
log_step "Artifacts on this run"
if ! gh api "repos/${REPO}/actions/runs/${RUN_ID}/artifacts" \
    -q '.artifacts[] | "\(.id) \(.size_in_bytes) \(.name) expired=\(.expired)"' 2>/dev/null \
    | awk '{ printf "%-14s %12d bytes  %s\n", $1, $2, substr($0, index($0,$3)) }'; then
    log_warn "Could not list artifacts for run ${RUN_ID}."
fi

# --- Verdict lines from the log ----------------------------------------------
if [[ "${OPT_LOG}" -eq 1 || "${OPT_LOG_FAILED}" -eq 1 ]]; then
    echo ""
    log_step "Verdict lines (boot gate / quota triage)"
    LOG_ARGS=(run view "${RUN_ID}" -R "${REPO}")
    [[ -n "${OPT_JOB}" ]] && LOG_ARGS+=(--job "${OPT_JOB}")
    if [[ "${OPT_LOG_FAILED}" -eq 1 ]]; then
        LOG_ARGS+=(--log-failed)
    else
        LOG_ARGS+=(--log)
    fi
    # The grep set used in real Phase 4/5 triage: gate verdicts, the KVM
    # proof line, artifact-quota failures, and step error markers.
    gh "${LOG_ARGS[@]}" 2>/dev/null \
        | grep -E "Test (PASSED|FAILED)|KVM acceleration|CreateArtifact|##\[error\]|CI_BOOT_OK|Grype (findings|severity)|DOUBLE_BUILD_(MATCH|DIFFER)" \
        || log_warn "No verdict lines matched (run may still be queued)."
fi
