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
# Load profile, enforce core-only composition (v1 scope)
# ---------------------------------------------------------------------------
load_profile "${PROFILE_NAME}"

if [[ "${DISTRO_EDITION}" != "core" || "${DISTRO_FLAVOR}" != "none" ]]; then
    log_error "v1 supports core-family profiles only (edition=core, flavor=none)."
    log_error "  Got: edition='${DISTRO_EDITION}' flavor='${DISTRO_FLAVOR}' (profile: ${PROFILE_NAME})"
    exit 1
fi

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
# Pin SOURCE_DATE_EPOCH before any derivation (same convention as
# build.sh): nothing below may read an unpinned clock. Ordering hygiene
# only - iso_build_date is wall-clock, so tarball-name date still comes
# from today, not the commit (see remediation plan B2 note).
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${OS_REPO_ROOT}" log -1 --pretty=%ct)}"
log_info "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}"

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
    # S9: an interrupted build between `bud` and the export-step `rmi`
    # leaves a local image-store entry behind. Guarded for set -u:
    # IMAGE_REF is only assigned in Step 3, cleanup runs from anywhere.
    if [[ -n "${IMAGE_REF:-}" ]]; then
        buildah rmi "${IMAGE_REF}" > /dev/null 2>&1 || true
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

# Container-functional extra, not layer content: the baked-in ShopnoOS repo
# (Q1) 301-redirects to https, so in-image apt needs CA certificates to
# update itself (upstream mmdebstrap manpage: install ca-certificates via
# --include when the chroot must update over https). Deliberately NOT a
# layer list entry - the ISO neither needs nor wants this coupling.
FINAL+=("ca-certificates")

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
    log_info "Would run: mmdebstrap --variant=minbase --architectures=${DISTRO_ARCH} --include=<${#FINAL[@]} pkgs> (+ Debian + jadupc sources, own keyring) ${LB_DISTRIBUTION} ${ROOTFS_DIR} ${LB_PARENT_MIRROR_BOOTSTRAP}"
    log_info "Would write: ${TARBALL_OUT} + ${MANIFEST_OUT}"
    exit 0
fi

require_command mmdebstrap buildah jq gpg

# ---------------------------------------------------------------------------
# Step 2: assemble APT sources (Debian + project repo) with own keyring
# ---------------------------------------------------------------------------
# live-build gets this for free (it merges base/config/archives/ into the
# chroot); mmdebstrap must be told explicitly. The project repo line
# mirrors jadupc.list verbatim; only signed-by is added (live-build keys
# archives differently - equivalent trust, different mechanism).
log_step "Assembling APT sources for mmdebstrap"

SOURCES_LIST="${WORKDIR}/sources.list"
# Debian lines carry an explicit signed-by pointing at the HOST keyring:
# mmdebstrap runs apt unchrooted (target dir overlaid, host trust store),
# so verification uses HOST /etc/apt/trusted.gpg.d - which has Debian keys
# on a Debian box (why local builds passed with bare lines) but only
# Ubuntu keys on a noble runner (hence NO_PUBKEY there). Explicit beats
# implicit on every host. (The jadupc line below brings its own keyring,
# so it never depended on host trust - which is why it fetched fine.)
DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
if [[ ! -f "${DEBIAN_KEYRING}" ]]; then
    log_error "Debian archive keyring not found on host: ${DEBIAN_KEYRING}"
    log_error "  Install it first (Debian/Ubuntu: debian-archive-keyring package;"
    log_error "  CI installs the pinned trixie .deb - see container-build.yml)."
    exit 1
fi
{
    echo "deb [signed-by=${DEBIAN_KEYRING}] ${LB_PARENT_MIRROR_BOOTSTRAP} ${LB_DISTRIBUTION} ${LB_APT_ARCHIVE_AREAS}"
    if [[ "${LB_UPDATES:-false}" == "true" ]]; then
        echo "deb [signed-by=${DEBIAN_KEYRING}] ${LB_PARENT_MIRROR_BOOTSTRAP} ${LB_DISTRIBUTION}-updates ${LB_APT_ARCHIVE_AREAS}"
    fi
} > "${SOURCES_LIST}"

JADUPC_KEY_ASC="${OS_REPO_ROOT}/base/config/archives/jadupc.key"
JADUPC_KEYRING="${WORKDIR}/jadupc.gpg"
# Canonical repo definition (B4, Golden Rule): parsed from jadupc.list,
# the same file live-build consumes - never retyped here. One-line `deb`
# shape only; anything else fails loud rather than guessing.
JADUPC_LIST="${OS_REPO_ROOT}/base/config/archives/jadupc.list"
require_file "${JADUPC_LIST}"
JADUPC_LINE="$(grep -v '^[[:space:]]*#' "${JADUPC_LIST}" | grep -m1 '^[[:space:]]*deb[[:space:]]' || true)"
test -n "${JADUPC_LINE}" || { log_error "No deb line in ${JADUPC_LIST}"; exit 1; }
case "${JADUPC_LINE}" in
    *"["*) log_error "Bracketed options in ${JADUPC_LIST} are unsupported - keep one-line deb form."; exit 1 ;;
esac
read -r _JADUPC_TYPE JADUPC_URL JADUPC_SUITE JADUPC_COMPS <<< "${JADUPC_LINE}"
test -n "${JADUPC_URL:-}" -a -n "${JADUPC_SUITE:-}" -a -n "${JADUPC_COMPS:-}" \
    || { log_error "Unparseable deb line in ${JADUPC_LIST}: ${JADUPC_LINE}"; exit 1; }
log_info "Project repo: ${JADUPC_URL} ${JADUPC_SUITE} ${JADUPC_COMPS} (from jadupc.list)"
# Host derived from the URL, never retyped: the scoped Verify-Peer opt
# below must name this exact host.
JADUPC_HOST="${JADUPC_URL#http://}"
JADUPC_HOST="${JADUPC_HOST#https://}"
JADUPC_HOST="${JADUPC_HOST%%/*}"
require_file "${JADUPC_KEY_ASC}"
# Dearmor at build time: the repo stores ASCII-armored, apt needs binary.
gpg --batch --yes --dearmor -o "${JADUPC_KEYRING}" "${JADUPC_KEY_ASC}"
echo "deb [signed-by=${JADUPC_KEYRING}] ${JADUPC_URL} ${JADUPC_SUITE} ${JADUPC_COMPS}" >> "${SOURCES_LIST}"
log_info "Sources: $(wc -l < "${SOURCES_LIST}" | tr -d ' ') lines ($(grep -c '^deb' "${SOURCES_LIST}") repos)"

# ---------------------------------------------------------------------------
# Step 2: build rootfs with mmdebstrap (rootless, deterministic w/ SDE)
# ---------------------------------------------------------------------------
log_step "Running mmdebstrap (${DISTRO_ARCH}, ${#FINAL[@]} packages)"

if command -v unshare > /dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then
    log_info "Rootless mode: user namespaces available"
else
    log_warn "User namespaces unavailable - mmdebstrap will run privileged (still fine, just needs root)"
fi

_run mmdebstrap \
    --variant=minbase \
    --architectures="${DISTRO_ARCH}" \
    --include="${INCLUDE_CSV}" \
    --aptopt="Dir::Etc::sourcelist \"${SOURCES_LIST}\"" \
    --aptopt="Dir::Etc::sourceparts \"-\"" \
    --aptopt="Acquire::https::${JADUPC_HOST}::Verify-Peer \"false\"" \
    "${LB_DISTRIBUTION}" \
    "${ROOTFS_DIR}" \
    "${LB_PARENT_MIRROR_BOOTSTRAP}"
# NOTE on the scoped Verify-Peer=false above: deb.jadupc.com 301-redirects
# to https, and a fresh minbase rootfs has no CA certificates when apt runs
# its first update - so that fetch cannot validate. Scoped to this host
# only; authenticity is still fully enforced via signed-by (every index and
# .deb verifies against the project key regardless of transport, which
# carries no credentials). If apt ever ignores the host scoping, the same
# failure as before (cert verification on first update) returns unchanged -
# escalate to build-time-only global Verify-Peer=false, same argument.

log_success "Rootfs built: $(du -sh "${ROOTFS_DIR}" | cut -f1)"

# Scrub mmdebstrap's build-time apt config from the image. --aptopt values
# are permanently written to /etc/apt/apt.conf.d/99mmdebstrap inside the
# chroot (manpage; "use hooks for temporary options") - including our
# Dir::Etc::sourcelist pointing at the build-time WORKDIR file and
# Dir::Etc::sourceparts "-". Shipped as-is, in-image apt reads NO source
# lists (proven empirically: smoke's hello install failed with an empty
# package cache while the old curl install passed vacuously). The scoped
# Verify-Peer=false goes with it - in-image TLS validates via the
# ca-certificates above, authenticity via signed-by, as everywhere else.
rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/99mmdebstrap"
log_info "Scrubbed build-time apt config (99mmdebstrap) from image"

# Q1 (baked, not sealed): ship the ShopnoOS repo inside the image so
# derived images can `apt install shopno-os-*` out of the box. Same key
# dearmored above, same URL/suite/components - installed to the standard
# keyring path with explicit signed-by, never trusted.gpg.d.
install -m 0755 -d "${ROOTFS_DIR}/usr/share/keyrings" "${ROOTFS_DIR}/etc/apt/sources.list.d"
install -m 0644 "${JADUPC_KEYRING}" "${ROOTFS_DIR}/usr/share/keyrings/jadupc.gpg"
echo "deb [signed-by=/usr/share/keyrings/jadupc.gpg] ${JADUPC_URL} ${JADUPC_SUITE} ${JADUPC_COMPS}" \
    > "${ROOTFS_DIR}/etc/apt/sources.list.d/jadupc.list"
log_info "In-image repo: ${JADUPC_URL} ${JADUPC_SUITE} ${JADUPC_COMPS} (keyring: /usr/share/keyrings/jadupc.gpg)"

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

# Standard OCI labels from brand identity; licenses label only when declared.
# image.source is the repo URL (GHCR links the package to it), image.url
# the project site - the two were previously swapped. image.version is the
# bare version matching :DISTRO_VERSION tags; codename keeps a vendor label.
# NOTE: URL_SOURCE currently points at the JaduPC org while this repo lives
# under fa-saikat (same drift as the old hardcoded IMAGE_NAME) - using the
# var as-is per the no-hardcode rule; fixing the URL itself is separate.
declare -a LABEL_FLAGS=(
    --label "org.opencontainers.image.title=${DISTRO_NAME} container base"
    --label "org.opencontainers.image.version=${DISTRO_VERSION}"
    --label "org.opencontainers.image.revision=${GIT_SHA}"
    --label "org.opencontainers.image.source=${URL_SOURCE}"
    --label "org.opencontainers.image.url=${DISTRO_WEBSITE}"
    --label "org.opencontainers.image.vendor=${DISTRO_VENDOR}"
    --label "org.opencontainers.image.created=$(date -u -d "@${SOURCE_DATE_EPOCH}" "+%Y-%m-%dT%H:%M:%SZ")"
    --label "org.shopno-os.codename=${DISTRO_CODENAME}"
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
# Vendor namespace sits alongside the reserved org.opencontainers.image.*
# prefix, never nested inside it (that prefix is the spec's own).
# Image config timestamp pinned to SOURCE_DATE_EPOCH (pinned above):
# otherwise every run stamps wall-clock and same-commit digests differ.
_run buildah bud \
    --format oci \
    --timestamp "${SOURCE_DATE_EPOCH}" \
    --arch "${DISTRO_ARCH}" \
    "${LABEL_FLAGS[@]}" \
    --label "org.shopno-os.profile=${PROFILE_NAME}" \
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
