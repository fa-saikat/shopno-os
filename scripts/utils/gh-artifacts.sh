#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-artifacts.sh
# ShopnoOS - List GitHub Actions artifacts, biggest first
#
# USAGE:
#   ./scripts/utils/gh-artifacts.sh [--run RUN_ID] [--limit N] [--total]
#     [--repo OWNER/REPO]
#
# PURPOSE:
#   Replaces the hand-typed `gh api .../actions/artifacts --paginate -q`
#   pipeline with one command. Lists artifacts sorted by size descending -
#   the order that matters when artifact storage quota is the reason
#   uploads fail red (see issue #64: `CreateArtifact: quota has been
#   hit` is environmental, and the fix starts with seeing what is big).
#   Each row shows the originating run ID + branch, so a fat artifact
#   leads straight back to gh-run-details.sh RUN_ID.
#
# OPTIONS:
#   --run RUN_ID   Only artifacts attached to one workflow run
#   --limit N      Show at most N rows (default: 20, 0 = no limit)
#   --total        Also print total count + total bytes (quota at a glance)
#   --repo R       OWNER/REPO (default: current repo, fallback
#                  fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help     Show this help
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
LIMIT=20
OPT_TOTAL=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --run)   RUN_ID="${2}"; shift 2 ;;
        --limit) LIMIT="${2}"; shift 2 ;;
        --total) OPT_TOTAL=1; shift ;;
        --repo)  REPO="${2}"; shift 2 ;;
        -h|--help) _usage 0 ;;
        -*)      log_error "Unknown option: ${1}"; _usage ;;
        *)       log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command gh jq

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

if [[ -n "${RUN_ID}" ]]; then
    ENDPOINT="repos/${REPO}/actions/runs/${RUN_ID}/artifacts"
else
    ENDPOINT="repos/${REPO}/actions/artifacts"
fi

JSON="$(gh api "${ENDPOINT}" --paginate)"

COUNT="$(echo "${JSON}" | jq '[.artifacts[]] | length')"
if [[ "${COUNT}" -eq 0 ]]; then
    log_info "No artifacts found${RUN_ID:+ on run ${RUN_ID}} (${REPO})."
    exit 0
fi

echo "${JSON}" \
    | jq -r '.artifacts | sort_by(-.size_in_bytes)[] | "\(.id)\t\(.size_in_bytes)\t\(.name)\t\(.created_at)\t\(.expired)\t\(.workflow_run.id // "-")\t\(.workflow_run.head_branch // "-")"' \
    | {
        if [[ "${LIMIT}" -gt 0 ]]; then head -n "${LIMIT}"; else cat; fi
      } \
    | awk -F'\t' '{
        size=$2; unit="B";
        if (size >= 1073741824)      { size=size/1073741824; unit="GiB"; }
        else if (size >= 1048576)    { size=size/1048576;    unit="MiB"; }
        else if (size >= 1024)       { size=size/1024;       unit="KiB"; }
        printf "%-14s %9.1f %-4s  %-32s  run=%-11s branch=%-28s  %s  expired=%s\n", $1, size, unit, $3, $6, $7, $4, $5
      }'

if [[ "${OPT_TOTAL}" -eq 1 ]]; then
    TOTAL_BYTES="$(echo "${JSON}" | jq '[.artifacts[].size_in_bytes] | add // 0')"
    log_info "Total: ${COUNT} artifact(s), $(numfmt --to=iec "${TOTAL_BYTES}" 2>/dev/null || echo "${TOTAL_BYTES} bytes")"
fi
