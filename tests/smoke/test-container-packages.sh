#!/usr/bin/env bash
# =============================================================================
# tests/smoke/test-container-packages.sh
# ShopnoOS - Container Content Gate (remediation C2)
#
# USAGE:
#   ./tests/smoke/test-container-packages.sh <tarball> [--profile NAME]
#     [--fixture PATH] [--sbom PATH]
#
# PURPOSE:
#   Artifact-derived content gate for the container image, ADR-003 style:
#   truth comes from dpkg inside the built artifact, never from re-summing
#   package lists. Three fail-loud checks:
#     1. Absence: no installed package matches container-exclude.txt -
#        the denylist is incomplete-by-construction, so the BUILT image
#        is audited, not the pattern list.
#     2. Critical: every critical_packages fixture entry is installed.
#     3. Ceiling/floor: installed count stays inside [total_min, total_max]
#        - growth is the risk for bases (loss is the risk for ISOs).
#   Plus an SBOM cross-check (second source) for the critical set.
#
#   Blocking CI step: deterministic, no virtualization. Uses the same
#   skopeo-to-docker bridge as the smoke test; the daemon is guaranteed
#   on hosted runners, rootless OCI runtimes are not.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PROFILE="shopno-os-core"
FIXTURE="${REPO_ROOT}/tests/fixtures/expected-container-packages.json"
SBOM=""

TARBALL=""
if [[ "${1:-}" != "" && "${1:-}" != -* ]]; then
    TARBALL="${1}"
    shift
fi
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile) PROFILE="${2}"; shift 2 ;;
        --fixture) FIXTURE="${2}"; shift 2 ;;
        --sbom)    SBOM="${2}"; shift 2 ;;
        -h|--help) sed -n '2,/^# ====/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: ${1}" >&2; exit 1 ;;
    esac
done

test -n "${TARBALL}" || { echo "Usage: $0 <tarball> [--profile NAME]" >&2; exit 1; }
test -f "${TARBALL}" || { echo "Tarball not found: ${TARBALL}" >&2; exit 1; }
test -f "${FIXTURE}" || { echo "Fixture not found: ${FIXTURE}" >&2; exit 1; }
command -v skopeo > /dev/null || { echo "Need skopeo" >&2; exit 1; }
command -v jq > /dev/null || { echo "Need jq" >&2; exit 1; }

EXCLUDE_FILE="${REPO_ROOT}/scripts/build/container-exclude.txt"
test -f "${EXCLUDE_FILE}" || { echo "Exclude file not found" >&2; exit 1; }

TAG="content-gate-test:${RANDOM}"
WORKDIR="$(mktemp -d /tmp/container-content-gate.XXXXXX)"
RUNTIME=""
CTR_ID=""
_cleanup_gate() {
    rm -rf "${WORKDIR}"
    if [[ "${RUNTIME}" == "docker" ]]; then
        docker rmi "${TAG}" > /dev/null 2>&1 || true
    elif [[ -n "${CTR_ID}" ]]; then
        buildah rm "${CTR_ID}" > /dev/null 2>&1 || true
    fi
}
trap '_cleanup_gate' EXIT

# Runtime: docker daemon if alive (CI path), else buildah working storage
# (bare-metal path - the daemon is frequently down there). Same dpkg truth
# either way. NOTE: no `--` separator on the buildah call below - rejected
# by this buildah version ("exec: no command"); callers never pass leading
# flags, so bare "$@"-style args are safe (see test-container-image.sh).
if docker info > /dev/null 2>&1; then
    RUNTIME="docker"
    echo "Loading image into docker..."
    skopeo copy "oci-archive:${TARBALL}" "docker-daemon:${TAG}" > /dev/null
else
    command -v buildah > /dev/null || { echo "Need a live docker daemon or buildah" >&2; exit 1; }
    RUNTIME="buildah"
    echo "Docker daemon unreachable - reading via buildah storage..."
    CTR_ID="$(buildah from "oci-archive:${TARBALL}")"
    [[ -n "${CTR_ID}" ]] || { echo "buildah from produced no container" >&2; exit 1; }
fi

echo "Reading installed package set from the artifact..."
if [[ "${RUNTIME}" == "docker" ]]; then
    docker run --rm "${TAG}" dpkg-query -W -f='${Package}\n' | sort -u > "${WORKDIR}/installed.txt"
else
    # `--` separator: proven safe on bare metal (the earlier "exec: no
    # command" failures were a missing crun binary, not this separator).
    buildah run "${CTR_ID}" -- dpkg-query -W -f='${Package}\n' | sort -u > "${WORKDIR}/installed.txt"
fi
INSTALLED="$(wc -l < "${WORKDIR}/installed.txt" | tr -d ' ')"
echo "Installed packages: ${INSTALLED}"

# Exclude patterns, same parsing as the build script: strip comments and
# all whitespace, skip blanks.
PATTERNS=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    pat="${line%%#*}"
    pat="${pat//[[:space:]]/}"
    [[ -z "${pat}" ]] && continue
    PATTERNS+=("${pat}")
done < "${EXCLUDE_FILE}"

FAIL=0

# 1. Absence: the denylist must hold against the built artifact.
echo "Check 1/3: denylist absence..."
LEAKED=()
while IFS= read -r pkg; do
    for pat in "${PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${pkg}" == ${pat} ]]; then
            LEAKED+=("${pkg} (${pat})")
            break
        fi
    done
done < "${WORKDIR}/installed.txt"
if [[ "${#LEAKED[@]}" -gt 0 ]]; then
    echo "FAIL: ${#LEAKED[@]} installed package(s) match an exclude pattern:"
    printf '  %s\n' "${LEAKED[@]}"
    FAIL=1
else
    echo "OK: no installed package matches the denylist."
fi

# 2. Critical list + 3. count band, both from the fixture.
echo "Check 2/3: critical packages..."
MISSING=()
while IFS= read -r pkg; do
    if ! grep -qxF "${pkg}" "${WORKDIR}/installed.txt"; then
        MISSING+=("${pkg}")
    fi
done < <(jq -r ".profiles[\"${PROFILE}\"].critical_packages[]" "${FIXTURE}")
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "FAIL: missing critical package(s): ${MISSING[*]}"
    FAIL=1
else
    echo "OK: all critical packages installed."
fi

echo "Check 3/3: count band..."
MIN="$(jq -r ".profiles[\"${PROFILE}\"].total_min" "${FIXTURE}")"
MAX="$(jq -r ".profiles[\"${PROFILE}\"].total_max" "${FIXTURE}")"
VALIDATED="$(jq -r ".profiles[\"${PROFILE}\"].validated_against_real_image" "${FIXTURE}")"
echo "Installed: ${INSTALLED}, band: [${MIN}, ${MAX}], validated: ${VALIDATED}"
if [[ "${INSTALLED}" -lt "${MIN}" || "${INSTALLED}" -gt "${MAX}" ]]; then
    echo "FAIL: count ${INSTALLED} outside [${MIN}, ${MAX}]."
    FAIL=1
else
    echo "OK: count inside band."
fi

# SBOM cross-check (second source): the critical set must appear there too.
if [[ -n "${SBOM}" ]]; then
    test -f "${SBOM}" || { echo "SBOM not found: ${SBOM}" >&2; exit 1; }
    echo "Cross-check: critical set against SBOM..."
    SBOM_MISSING=()
    while IFS= read -r pkg; do
        if ! jq -e --arg p "${pkg}" '.packages[] | select(.name == $p)' "${SBOM}" > /dev/null; then
            SBOM_MISSING+=("${pkg}")
        fi
    done < <(jq -r ".profiles[\"${PROFILE}\"].critical_packages[]" "${FIXTURE}")
    SBOM_COUNT="$(jq '.packages | length' "${SBOM}")"
    echo "SBOM packages: ${SBOM_COUNT} vs installed: ${INSTALLED}"
    if [[ "${#SBOM_MISSING[@]}" -gt 0 ]]; then
        echo "FAIL: critical package(s) missing from SBOM: ${SBOM_MISSING[*]}"
        FAIL=1
    else
        echo "OK: critical set present in SBOM."
    fi
fi

if [[ "${FAIL}" -ne 0 ]]; then
    echo "CONTENT GATE FAILED." >&2
    exit 1
fi
echo "CONTENT GATE PASSED."
