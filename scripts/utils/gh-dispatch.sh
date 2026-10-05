#!/usr/bin/env bash
# =============================================================================
# scripts/utils/gh-dispatch.sh
# ShopnoOS - Dispatch a workflow run and optionally watch it
#
# USAGE:
#   ./scripts/utils/gh-dispatch.sh [--workflow iso|container]
#     [--profile NAME] [--ref BRANCH] [--watch] [--repo OWNER/REPO]
#
# PURPOSE:
#   Wraps the T4 throwaway-branch pattern (`gh workflow run "Build ISO"
#   --ref <branch> -f profile=...`) so proving one profile outside the PR
#   path - how desktop-xfce was first proven, how gaming-xfce stays
#   dispatch-only - stops being a reconstructed one-liner.
#
# OPTIONS:
#   --workflow W   iso (Build ISO, default) | container (Build Container)
#   --profile P    Profile to build. Defaults: shopno-os-core for iso
#                  (any profile/* name is accepted - gaming-xfce stays
#                  dispatch-only by workflow design, see docs/ci-cd.md §8);
#                  shopno-os-core for container (v1: core only, the
#                  workflow's own guard rejects the rest).
#   --ref B        Git ref to dispatch on (default: current branch).
#                  The ref must already be pushed - dispatching an
#                  unpushed branch fails server-side.
#   --watch        Tail the new run with `gh run watch` after dispatch.
#   --repo R       OWNER/REPO (default: current repo, fallback
#                  fa-saikat/shopno-os). GH_REPO env also honored.
#   -h, --help     Show this help
#
# PREREQUISITES:
#   gh (authenticated). `git` for the current-branch default.
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

WORKFLOW="iso"
PROFILE=""
REF=""
OPT_WATCH=0
REPO="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --workflow) WORKFLOW="${2}"; shift 2 ;;
        --profile)  PROFILE="${2}"; shift 2 ;;
        --ref)      REF="${2}"; shift 2 ;;
        --watch)    OPT_WATCH=1; shift ;;
        --repo)     REPO="${2}"; shift 2 ;;
        -h|--help)  _usage 0 ;;
        -*)         log_error "Unknown option: ${1}"; _usage ;;
        *)          log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command gh git

if [[ -z "${REPO}" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo fa-saikat/shopno-os)"
fi

case "${WORKFLOW}" in
    iso)       WORKFLOW_FILE="build-iso.yml";      DEFAULT_PROFILE="shopno-os-core" ;;
    container) WORKFLOW_FILE="container-build.yml"; DEFAULT_PROFILE="shopno-os-core" ;;
    *)         die "Unknown workflow '${WORKFLOW}' - use iso or container." ;;
esac

PROFILE="${PROFILE:-${DEFAULT_PROFILE}}"

if [[ -z "${REF}" ]]; then
    REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev)"
fi

# Soft guard: warn on profiles the repo does not define, but let the
# workflow decide - dispatch inputs are validated server-side too.
if [[ ! -d "${OS_REPO_ROOT}/profiles/${PROFILE}" ]]; then
    log_warn "No profiles/${PROFILE}/ in this checkout - dispatching anyway (server decides)."
fi

log_info "Dispatching ${WORKFLOW_FILE} on ${REF} with profile=${PROFILE} (${REPO})"
gh workflow run "${WORKFLOW_FILE}" -R "${REPO}" --ref "${REF}" -f "profile=${PROFILE}"

if [[ "${OPT_WATCH}" -eq 1 ]]; then
    log_info "Waiting for the run to appear..."
    NEW_ID=""
    for _ in $(seq 1 6); do
        sleep 5
        NEW_ID="$(gh run list -R "${REPO}" --workflow "${WORKFLOW_FILE}" --limit 1 \
            --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
        [[ -n "${NEW_ID}" ]] && break
    done
    [[ -n "${NEW_ID}" ]] || die "No run appeared for ${WORKFLOW_FILE} - check gh-runs.sh."
    log_info "Watching run ${NEW_ID} (Ctrl-C stops the tail, not the run)."
    gh run watch "${NEW_ID}" -R "${REPO}"
fi
