#!/usr/bin/env bash
# =============================================================================
# scripts/release/changelog-gen.sh
# ShopnoOS — Changelog Generator
#
# USAGE:
#   ./scripts/release/changelog-gen.sh                    # since last tag
#   ./scripts/release/changelog-gen.sh v1.0 v1.1         # between two tags/refs
#   ./scripts/release/changelog-gen.sh --version 1.1     # set release version header
#   ./scripts/release/changelog-gen.sh --format md       # markdown (default)
#   ./scripts/release/changelog-gen.sh --format deb      # Debian changelog format
#   ./scripts/release/changelog-gen.sh --output FILE      # write to file
#   ./scripts/release/changelog-gen.sh --update           # prepend to CHANGELOG.md
#
# COMMIT CONVENTION (conventional commits assumed):
#   feat:       → Features
#   fix:        → Bug Fixes
#   docs:       → Documentation
#   chore:      → Chores / Maintenance
#   refactor:   → Refactoring
#   perf:       → Performance
#   build:      → Build System
#   ci:         → CI/CD
#   test:       → Tests
#   BREAKING:   → Breaking Changes (section promoted to top)
#
# OUTPUT FORMATS:
#   md    — Markdown (default), suitable for GitHub releases
#   deb   — Debian changelog format (debian/changelog compatible)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/brand.sh
source "${LIB_DIR}/brand.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
REF_FROM=""
REF_TO="HEAD"
OPT_VERSION="${DISTRO_VERSION}"
OPT_FORMAT="md"
OPT_OUTPUT=""
OPT_UPDATE=0

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [from-ref [to-ref]] [options]

Options:
  --version V      Release version for header (default: DISTRO_VERSION)
  --format  F      Output format: md (default) or deb
  --output  FILE   Write to file instead of stdout
  --update         Prepend generated log to CHANGELOG.md
  -h, --help       Show this help
EOF
    exit 1
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --version)  OPT_VERSION="${2}"; shift ;;
        --format)   OPT_FORMAT="${2}";  shift ;;
        --output)   OPT_OUTPUT="${2}";  shift ;;
        --update)   OPT_UPDATE=1 ;;
        -h|--help)  _usage ;;
        -*)         log_error "Unknown option: ${1}"; _usage ;;
        *)          POSITIONAL+=("${1}") ;;
    esac
    shift
done

if [[ ${#POSITIONAL[@]} -ge 1 ]]; then REF_FROM="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then REF_TO="${POSITIONAL[1]}"; fi

# Validate format
if [[ "${OPT_FORMAT}" != "md" && "${OPT_FORMAT}" != "deb" ]]; then
    log_error "Unknown format '${OPT_FORMAT}'. Use: md or deb"
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine git range
# ---------------------------------------------------------------------------
require_command git

cd "${LIB_REPO_ROOT}"

if [[ -z "${REF_FROM}" ]]; then
    # Find the most recent tag
    LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "${LAST_TAG}" ]]; then
        REF_FROM="${LAST_TAG}"
        log_info "Auto-detected last tag: ${REF_FROM}"
    else
        log_warn "No git tags found — generating full history changelog."
        REF_FROM=""
    fi
fi

GIT_RANGE="${REF_FROM:+${REF_FROM}..}${REF_TO}"
log_info "Git range: ${GIT_RANGE:-<all commits>}"

# ---------------------------------------------------------------------------
# Collect commits
# ---------------------------------------------------------------------------
# Format: <hash>|<subject>|<author>|<date>
mapfile -t COMMITS < <(
    git log "${GIT_RANGE}" \
        --pretty=format:"%H|%s|%an|%as" \
        --no-merges \
        2>/dev/null || true
)

log_info "Commits found: ${#COMMITS[@]}"

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    log_warn "No commits in range ${GIT_RANGE} — empty changelog."
fi

# ---------------------------------------------------------------------------
# Categorise commits
# ---------------------------------------------------------------------------
declare -a BREAKING=()
declare -a FEATURES=()
declare -a FIXES=()
declare -a DOCS=()
declare -a BUILD=()
declare -a CI=()
declare -a CHORES=()
declare -a OTHER=()

_format_commit() {
    local hash="${1}"
    local subject="${2}"
    local short_hash="${hash:0:8}"

    # Strip conventional commit prefix for display
    local clean_subject
    clean_subject="${subject#*: }"

    echo "- ${clean_subject} (\`${short_hash}\`)"
}

for commit_line in "${COMMITS[@]}"; do
    IFS='|' read -r hash subject author date <<< "${commit_line}"

    formatted="$(_format_commit "${hash}" "${subject}")"

    if echo "${subject}" | grep -qiE 'BREAKING[ -]CHANGE|!:'; then
        BREAKING+=("${formatted}")
    elif echo "${subject}" | grep -qE '^feat(\(.+\))?[!]?:'; then
        FEATURES+=("${formatted}")
    elif echo "${subject}" | grep -qE '^fix(\(.+\))?[!]?:'; then
        FIXES+=("${formatted}")
    elif echo "${subject}" | grep -qE '^docs(\(.+\))?:'; then
        DOCS+=("${formatted}")
    elif echo "${subject}" | grep -qE '^build(\(.+\))?:'; then
        BUILD+=("${formatted}")
    elif echo "${subject}" | grep -qE '^ci(\(.+\))?:'; then
        CI+=("${formatted}")
    elif echo "${subject}" | grep -qE '^(chore|refactor|perf|test)(\(.+\))?:'; then
        CHORES+=("${formatted}")
    else
        OTHER+=("${formatted}")
    fi
done

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
RELEASE_DATE="$(date -u +%Y-%m-%d)"
OUTPUT_BUFFER=""

_section_md() {
    local title="${1}"
    local -n _entries="${2}"
    [[ ${#_entries[@]} -eq 0 ]] && return 0
    OUTPUT_BUFFER+=$'\n'"### ${title}"$'\n'$'\n'
    for entry in "${_entries[@]}"; do
        OUTPUT_BUFFER+="${entry}"$'\n'
    done
}

_section_deb() {
    local title="${1}"
    local -n _entries="${2}"
    [[ ${#_entries[@]} -eq 0 ]] && return 0
    OUTPUT_BUFFER+="  [ ${title} ]"$'\n'
    for entry in "${_entries[@]}"; do
        # Debian format: leading '  * '
        local clean="${entry#- }"
        OUTPUT_BUFFER+="  * ${clean}"$'\n'
    done
    OUTPUT_BUFFER+=$'\n'
}

if [[ "${OPT_FORMAT}" == "md" ]]; then
    OUTPUT_BUFFER="## [${OPT_VERSION}] — ${RELEASE_DATE}"$'\n'

    _section_md "⚠️ Breaking Changes"  BREAKING
    _section_md "✨ Features"          FEATURES
    _section_md "🐛 Bug Fixes"         FIXES
    _section_md "📖 Documentation"     DOCS
    _section_md "🔧 Build System"      BUILD
    _section_md "🤖 CI/CD"             CI
    _section_md "🧹 Maintenance"       CHORES
    [[ ${#OTHER[@]} -gt 0 ]] && _section_md "📦 Other" OTHER

    # Footer
    if [[ -n "${REF_FROM}" ]]; then
        OUTPUT_BUFFER+=$'\n'"---"$'\n'
        COMPARE_URL="${DISTRO_BUGTRACKER%/issues}"
        OUTPUT_BUFFER+="**Full diff:** \`${REF_FROM}...${OPT_VERSION}\`"$'\n'
    fi

elif [[ "${OPT_FORMAT}" == "deb" ]]; then
    DISTRO_ID_LOWER="${DISTRO_ID,,}"
    OUTPUT_BUFFER="${DISTRO_ID_LOWER} (${OPT_VERSION}) stable; urgency=medium"$'\n'$'\n'

    _section_deb "Breaking Changes"  BREAKING
    _section_deb "New Features"      FEATURES
    _section_deb "Bug Fixes"         FIXES
    _section_deb "Documentation"     DOCS
    _section_deb "Build System"      BUILD
    _section_deb "Maintenance"       CHORES
    [[ ${#OTHER[@]} -gt 0 ]] && _section_deb "Other" OTHER

    # Maintainer line (required by Debian format)
    MAINTAINER_NAME="${DISTRO_NAME} Maintainers"
    MAINTAINER_EMAIL="maintainer@${DISTRO_WEBSITE#https://}"
    DEB_DATE="$(date -u -R)"
    OUTPUT_BUFFER+=" -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  ${DEB_DATE}"$'\n'
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "${OPT_UPDATE}" -eq 1 ]]; then
    CHANGELOG="${LIB_REPO_ROOT}/CHANGELOG.md"
    if [[ -f "${CHANGELOG}" ]]; then
        TMP="$(mktemp)"
        echo "${OUTPUT_BUFFER}" > "${TMP}"
        echo "" >> "${TMP}"
        cat "${CHANGELOG}" >> "${TMP}"
        mv "${TMP}" "${CHANGELOG}"
    else
        echo "${OUTPUT_BUFFER}" > "${CHANGELOG}"
    fi
    log_success "CHANGELOG.md updated: ${CHANGELOG}"

elif [[ -n "${OPT_OUTPUT}" ]]; then
    echo "${OUTPUT_BUFFER}" > "${OPT_OUTPUT}"
    log_success "Changelog written: ${OPT_OUTPUT}"

else
    echo "${OUTPUT_BUFFER}"
fi
