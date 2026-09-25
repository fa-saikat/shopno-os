#!/usr/bin/env bash
# =============================================================================
# scripts/build/build-container.sh
# ShopnoOS - OCI Container Image Builder (Phase 4, slice 1)
#
# USAGE:
#   ./scripts/build/build-container.sh [--profile shopno-os-core] [--output-dir D] [--dry-run] [--keep-rootfs]
#
# PURPOSE:
#   Builds a minimal, deterministic ShopnoOS OCI image from the same brand
#   identity and package philosophy as the ISOs - without reusing the
#   live-build chroot (live-boot/live-config state is meaningless and
#   previously proven harmful outside a live session) and without touching
#   any layer. v1 builds the core composition only.
#
#   This script writes a local OCI tarball + manifest. It never pushes to a
#   registry (the CI workflow does that), never signs, never scans - those
#   are separate slices consuming this script's output.
#
# OPTIONS:
#   --profile P    Build profile, core-family only (default: shopno-os-core)
#   --output-dir D Directory for tarball + manifest (default: build/container/)
#   --jobs N       Reserved for future parallel steps (default: nproc)
#   --dry-run      Print plan, do not execute
#   --keep-rootfs  Keep the unpacked rootfs tree for inspection
#   -h, --help     Show this help
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Bootstrap: resolve repo root and source libs (same order as build.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/brand.sh
source "${LIB_DIR}/brand.sh"
# shellcheck source=../lib/profile.sh
source "${LIB_DIR}/profile.sh"
# shellcheck source=../lib/iso-name.sh
source "${LIB_DIR}/iso-name.sh"
# shellcheck source=../lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PROFILE_NAME="shopno-os-core"
OPT_OUTPUT_DIR="${OS_REPO_ROOT}/build/container"
OPT_DRY_RUN=0
OPT_KEEP_ROOTFS=0

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [options]

Options:
  --profile P     Core-family profile only (default: shopno-os-core)
  --output-dir D  Output dir for tarball + manifest (default: build/container/)
  --dry-run       Print plan, do not build
  --keep-rootfs   Keep unpacked rootfs tree for inspection
  -h, --help      Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile)    PROFILE_NAME="${2}"; shift ;;
        --output-dir) OPT_OUTPUT_DIR="${2}"; shift ;;
        --dry-run)    OPT_DRY_RUN=1 ;;
        --keep-rootfs) OPT_KEEP_ROOTFS=1 ;;
        -h|--help)    _usage ;;
        -*)           log_error "Unknown option: ${1}"; _usage ;;
        *)            log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Load profile + secrets, enforce core-only composition (v1 scope)
# ---------------------------------------------------------------------------
load_profile "${PROFILE_NAME}"
load_secrets

if [[ "${DISTRO_EDITION}" != "core" || "${DISTRO_FLAVOR}" != "none" ]]; then
    log_error "v1 supports core-family profiles only (edition=core, flavor=none)."
    log_error "  Got: edition='${DISTRO_EDITION}' flavor='${DISTRO_FLAVOR}' (profile: ${PROFILE_NAME})"
    exit 1
fi

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
BUILD_DATE="$(iso_build_date)"
TARBALL_NAME="shopno-os-${DISTRO_VERSION}-core-${DISTRO_ARCH}-${BUILD_DATE}.oci.tar"
WORKDIR="$(mktemp -d /tmp/shopno-os-container.XXXXXX)"
ROOTFS_DIR="${WORKDIR}/rootfs"
TARBALL_OUT="${OPT_OUTPUT_DIR}/${TARBALL_NAME}"
MANIFEST_OUT="${OPT_OUTPUT_DIR}/container-manifest.json"
EXCLUDE_FILE="${SCRIPT_DIR}/container-exclude.txt"
require_file "${EXCLUDE_FILE}"

_cleanup() {
    if [[ "${OPT_KEEP_ROOTFS}" -eq 1 ]]; then
        log_info "Rootfs kept at: ${ROOTFS_DIR}"
        return 0
    fi
    rm -rf "${WORKDIR}"
}
trap '_cleanup' EXIT

# ---------------------------------------------------------------------------
# Step 1: resolve package set (canonical lists minus container exclusions)
# ---------------------------------------------------------------------------
log_step "Resolving container package set"

declare -a DECLARED=()
while IFS= read -r f; do
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip inline comments, all whitespace; skip blanks + full comments
        pkg="${line%%#*}"
        pkg="${pkg//[[:space:]]/}"
        [[ -z "${pkg}" ]] && continue
        # Strip version constraints: 'curl (>= 7.68)' -> 'curl'; take first token
        pkg="${pkg%%(*}"
        pkg="${pkg%% *}"
        [[ -z "${pkg}" ]] && continue
        DECLARED+=("$(echo "${pkg}" | tr '[:upper:]' '[:lower:]')")
    done < "${f}"
done < <(profile_package_lists)

# Deduplicate preserving order
declare -A _SEEN=()
declare -a UNIQUE=()
for pkg in "${DECLARED[@]}"; do
    if [[ -z "${_SEEN[${pkg}]+_}" ]]; then
        _SEEN["${pkg}"]=1
        UNIQUE+=("${pkg}")
    fi
done

# Load exclusion patterns (skip blanks/comments)
declare -a EXCLUDES=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    pat="${line%%#*}"
    pat="${pat//[[:space:]]/}"
    [[ -z "${pat}" ]] && continue
    EXCLUDES+=("${pat}")
done < "${EXCLUDE_FILE}"

# Subtract: a package matching ANY pattern is out (logged once at debug)
declare -a FINAL=()
declare -a DROPPED=()
for pkg in "${UNIQUE[@]}"; do
    excluded=0
    for pat in "${EXCLUDES[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${pkg}" == ${pat} ]]; then
            excluded=1
            DROPPED+=("${pkg} (${pat})")
            break
        fi
    done
    [[ "${excluded}" -eq 0 ]] && FINAL+=("${pkg}")
done

log_info "Declared (base+core, unique): ${#UNIQUE[@]}"
log_info "Excluded (container-wrong)   : ${#DROPPED[@]}"
log_info "Final (into image)           : ${#FINAL[@]}"
for entry in "${DROPPED[@]}"; do
    log_debug "  dropped: ${entry}"
done

# Backstop: re-validate FINAL against EXCLUDES with the same matcher.
# Stated precisely so this is never mistaken for a completeness
# guarantee: it cannot catch "a package nobody wrote a pattern for"
# (nothing can, short of the artifact-absence check tracked separately).
# What it catches is drift INSIDE this script - a future refactor of the
# subtraction loop above (different matching semantics, a restructured
# break, a parallel rewrite) that silently stops excluding. Same rules
# today means silent today; the value is entirely in firing the day the
# two loops disagree.
declare -a LEAKED=()
for pkg in "${FINAL[@]}"; do
    for pat in "${EXCLUDES[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${pkg}" == ${pat} ]]; then
            LEAKED+=("${pkg} (${pat})")
            break
        fi
    done
done
if [[ "${#LEAKED[@]}" -gt 0 ]]; then
    log_error "Backstop check failed - ${#LEAKED[@]} package(s) in FINAL still match an exclude pattern:"
    for entry in "${LEAKED[@]}"; do
        log_error "  ${entry}"
    done
    log_error "The subtraction loop above let these through - investigate it, not the pattern list."
    exit 1
fi

# Refuse to build a vacuous image - an empty set is a bug, not minimalism
[[ "${#FINAL[@]}" -gt 0 ]] \
    || { log_error "Exclusions removed every package - refusing to build an empty image."; exit 1; }

INCLUDE_CSV="$(IFS=,; echo "${FINAL[*]}")"

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_warn "DRY RUN - no files will be modified."
    log_info "Would run: mmdebstrap --variant=minbase --architectures=${DISTRO_ARCH} --include=<${#FINAL[@]} pkgs> ${LB_DISTRIBUTION} ${ROOTFS_DIR} ${LB_PARENT_MIRROR_BOOTSTRAP}"
    log_info "Would write: ${TARBALL_OUT} + ${MANIFEST_OUT}"
    exit 0
fi

require_command mmdebstrap buildah jq

# ---------------------------------------------------------------------------
# Step 2: build rootfs with mmdebstrap (rootless, deterministic w/ SDE)
# ---------------------------------------------------------------------------
log_step "Running mmdebstrap (${DISTRO_ARCH}, ${#FINAL[@]} packages)"

if command -v unshare > /dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then
    log_info "Rootless mode: user namespaces available"
else
    log_warn "User namespaces unavailable - mmdebstrap will run privileged (still fine, just needs root)"
fi

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${OS_REPO_ROOT}" log -1 --pretty=%ct)}"
log_info "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}"

_run mmdebstrap \
    --variant=minbase \
    --architectures="${DISTRO_ARCH}" \
    --include="${INCLUDE_CSV}" \
    "${LB_DISTRIBUTION}" \
    "${ROOTFS_DIR}" \
    "${LB_PARENT_MIRROR_BOOTSTRAP}"

log_success "Rootfs built: $(du -sh "${ROOTFS_DIR}" | cut -f1)"

# Tar the rootfs for the Containerfile ADD. Fully pinned for
# reproducibility: sorted members, clamped mtimes, fixed ownership -
# otherwise readdir order alone makes same-commit digests differ.
ROOTFS_TAR="${WORKDIR}/rootfs.tar"
_run tar -C "${ROOTFS_DIR}" -cf "${ROOTFS_TAR}" \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --clamp-mtime \
    --owner=0 --group=0 --numeric-owner \
    .

# ---------------------------------------------------------------------------
# Step 3: assemble OCI image with buildah (daemonless)
# ---------------------------------------------------------------------------
log_step "Assembling OCI image with buildah"

GIT_SHA="$(git -C "${OS_REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

# Standard OCI labels from brand identity; licenses label only when declared
declare -a LABEL_FLAGS=(
    --label "org.opencontainers.image.title=${DISTRO_NAME} container base"
    --label "org.opencontainers.image.version=${DISTRO_VERSION} (${DISTRO_CODENAME})"
    --label "org.opencontainers.image.revision=${GIT_SHA}"
    --label "org.opencontainers.image.source=${DISTRO_WEBSITE}"
    --label "org.opencontainers.image.created=$(date -u -d "@${SOURCE_DATE_EPOCH}" "+%Y-%m-%dT%H:%M:%SZ")"
)
if [[ -n "${DISTRO_LICENSE:-}" ]]; then
    LABEL_FLAGS+=(--label "org.opencontainers.image.licenses=${DISTRO_LICENSE}")
fi

cat > "${WORKDIR}/Containerfile" <<EOF
FROM scratch
ADD rootfs.tar /
CMD ["/bin/bash"]
EOF

IMAGE_REF="shopno-os-container:${DISTRO_VERSION}-${GIT_SHA}"
_run buildah bud \
    --format oci \
    --arch "${DISTRO_ARCH}" \
    "${LABEL_FLAGS[@]}" \
    -t "${IMAGE_REF}" \
    -f "${WORKDIR}/Containerfile" \
    "${WORKDIR}"

# ---------------------------------------------------------------------------
# Step 4: export tarball + manifest
# ---------------------------------------------------------------------------
log_step "Exporting image tarball and manifest"

mkdir -p "${OPT_OUTPUT_DIR}"
# --digestfile is the only reliable digest source: `buildah inspect`
# reports no Digest field for local-store images (verified empirically).
# Capture AFTER push, fail loud on empty - a manifest with a blank digest
# is worse than no manifest.
_run buildah push --digestfile "${WORKDIR}/digestfile" "${IMAGE_REF}" "oci-archive:${TARBALL_OUT}"
IMAGE_DIGEST="$(cat "${WORKDIR}/digestfile")"
[[ -n "${IMAGE_DIGEST}" ]] \
    || { log_error "Empty digest after push - refusing to stamp manifest."; exit 1; }
log_info "Image digest: ${IMAGE_DIGEST}"

# Remove the local image store entry - the tarball is the artifact
buildah rmi "${IMAGE_REF}" > /dev/null 2>&1 || true

jq -n \
    --arg schema_version "1" \
    --arg name            "${DISTRO_NAME}" \
    --arg id              "${DISTRO_ID}" \
    --arg version         "${DISTRO_VERSION}" \
    --arg codename        "${DISTRO_CODENAME}" \
    --arg profile         "${PROFILE_NAME}" \
    --arg arch            "${DISTRO_ARCH}" \
    --arg build_date      "${BUILD_DATE}" \
    --arg git_commit      "$(git -C "${OS_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")" \
    --argjson declared    "${#UNIQUE[@]}" \
    --argjson excluded    "${#DROPPED[@]}" \
    --argjson final       "${#FINAL[@]}" \
    --arg tarball         "$(basename "${TARBALL_OUT}")" \
    --arg digest          "${IMAGE_DIGEST}" \
    '{
        schema_version: $schema_version,
        distro: {
            name:     $name,
            id:       $id,
            version:  $version,
            codename: $codename
        },
        build: {
            profile:    $profile,
            arch:       $arch,
            date:       $build_date,
            git_commit: $git_commit
        },
        package: {
            declared: $declared,
            excluded: $excluded,
            final:    $final
        },
        output: {
            tarball: $tarball,
            digest:  $digest
        }
    }' > "${MANIFEST_OUT}"

log_success "Tarball : ${TARBALL_OUT}"
log_success "Manifest: ${MANIFEST_OUT}"
log_info "Total time: $((SECONDS / 60))m $((SECONDS % 60))s"
