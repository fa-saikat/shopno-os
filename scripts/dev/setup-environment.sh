#!/usr/bin/env bash
# =============================================================================
# scripts/dev/setup-environment.sh
# ShopnoOS - Cold-Machine Environment Setup (Debian trixie only)
#
# USAGE:
#   ./scripts/dev/setup-environment.sh [--unattended] [--dry-run]
#
# PURPOSE:
#   New machine? Clone the repo, run this, answer a few prompts - the
#   script installs every build/dev tool, wires KVM/libvirt, guides gh +
#   registry auth, and onboards credentials (GPG key, mirror creds,
#   tokens) with import / set-up-new / skip choices each. Console stays
#   clean (one line per step); everything verbose lands in a timestamped
#   setup-*.log next to this run.
#
# RULES (do not weaken):
#   - Debian trixie (or newer Debian) only. Anything else aborts loud -
#     guessing package names across apt ecosystems is how broken builders
#     are born. Ubuntu explicitly unsupported (no live-build package).
#   - Secrets discipline: values are NEVER written to the log (see
#     run_sensitive), secret files get 600 perms, skipping is always an
#     explicit logged choice - never nagging, never defaulted silently.
#   - Idempotent: safe to re-run; every step checks state first and
#     prints SKIP when there is nothing to do.
#
# OPTIONS:
#   --unattended   No prompts: install everything, skip all credentials.
#                  (Lets CI at least syntax/existence-check this script.)
#   --dry-run      Print what would happen on THIS machine without
#                  changing anything: detection stays live, every mutation
#                  (apt, usermod, file writes, prompts) becomes a logged
#                  no-op. Always exits 0 - a preview is not a verdict.
#   -h, --help     Show this help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

OPT_UNATTENDED=0
OPT_DRY_RUN=0

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--unattended]

  --unattended   Install everything, skip all credential prompts
  -h, --help     Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --unattended) OPT_UNATTENDED=1 ;;
        --dry-run)    OPT_DRY_RUN=1 ;;
        -h|--help)    _usage ;;
        *) log_error "Unknown option: ${1}"; _usage ;;
    esac
    shift
done

REPO_ROOT="${OS_REPO_ROOT}"
LOG_FILE="/tmp/shopno-os-setup-$(date +%Y%m%d-%H%M%S).log"
SECRETS_DIR="${REPO_ROOT}/secrets"

# ---------------------------------------------------------------------------
# Logging: console gets one line per step, the file gets everything.
# run_sensitive logs the command SHAPE with values redacted - values must
# never reach the logfile. Keep it that way.
# ---------------------------------------------------------------------------
_timestamp() { date "+%H:%M:%S"; }

log_run() {
    echo "[$(_timestamp)] \$ $*" >> "${LOG_FILE}"
    "$@" >> "${LOG_FILE}" 2>&1
}

run_sensitive() {
    echo "[$(_timestamp)] \$ $1 [REDACTED]" >> "${LOG_FILE}"
    shift
    "$@" >> "${LOG_FILE}" 2>&1
}

# sudo_log runs a privileged command with output appended to the logfile.
# (Plain `sudo cmd >> file` redirects as the CALLING user, not root.
# Pipe through tee instead; pipefail, already set, preserves the
# failure exit code.)
# Under --dry-run nothing executes: the would-be command is logged and
# success is reported so the preview reads end to end.
sudo_log() {
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would run (privileged): $*"
        return 0
    fi
    sudo "$@" 2>&1 | tee -a "${LOG_FILE}" > /dev/null
}

step_ok()   { log_success "$1"; echo "[$(_timestamp)] OK: $1" >> "${LOG_FILE}"; }
step_skip() { log_info "$1 (skipped)"; echo "[$(_timestamp)] SKIP: $1" >> "${LOG_FILE}"; }
step_fail() { log_error "$1"; echo "[$(_timestamp)] FAIL: $1" >> "${LOG_FILE}"; }

echo "Environment setup log - $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${LOG_FILE}"
log_info "Full log: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "${1}" > /dev/null 2>&1; }

ask_choice() {
    # ask_choice "Title" "opt1" "opt2" ... -> prints selection, always succeeds
    local title="${1}"; shift
    if [[ "${OPT_UNATTENDED}" -eq 1 ]]; then
        echo "skip"
        return 0
    fi
    # Dry-run short-circuit (single point): every credential prompt in steps
    # 5-8 flows through here, so answering "skip" here guarantees no gum
    # prompt, no file write, and no mutation downstream - the branches
    # already treat "skip" as do-nothing.
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would ask: ${title} [$*]"
        echo "skip"
        return 0
    fi
    gum choose --header "${title}" "$@" < /dev/tty
}

# ---------------------------------------------------------------------------
# Step 0: distro gate + gum bootstrap (gum IS the UI - no fallback UI is
# implemented on purpose; two prompt systems is two to maintain)
# ---------------------------------------------------------------------------
log_step "Step 0/8 - Host check"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log_info "Detected: ${PRETTY_NAME:-${ID} ${VERSION_ID}} (ID=${ID:-?})"
else
    step_fail "No /etc/os-release - cannot identify host."
    exit 1
fi
if [[ "${ID:-}" != "debian" ]]; then
    step_fail "Debian only (tested base: trixie). Got ID='${ID:-unknown}' - aborting, nothing installed."
    exit 1
fi

# Virtualization notice (informational only - never blocks): a guest
# without CPU passthrough has no /dev/kvm, so KVM-dependent steps verify
# red through no fault of the script. Say so up front, in plain words.
VIRT_KIND="none"
if have_cmd systemd-detect-virt; then
    # NOTE: exit status is useless here (non-zero on bare metal too) and
    # set -e aborts on a failing substitution - swallow the status, then
    # treat empty as bare metal. The printed word is the only signal.
    VIRT_KIND="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "${VIRT_KIND}" ]] && VIRT_KIND="none"
fi
if [[ "${VIRT_KIND}" != "none" ]]; then
    log_warn "Running inside a virtual machine (${VIRT_KIND}) - heads up:"
    log_warn "  - No /dev/kvm unless the host passes the CPU through:"
    log_warn "    QEMU boot tests fall back to TCG (slow but working)."
    log_warn "  - Nested libvirt inside here is limited; manage VMs from the host instead."
    log_warn "  - For the full experience (KVM boot gates, fast builds): bare metal."
    log_warn "  - Everything else below works identically in a VM."
    echo "[$(date +%H:%M:%S)] NOTICE: guest virt detected (${VIRT_KIND})" >> "${LOG_FILE}"
fi

# Resource check (warn-only, never blocks): thresholds from measured builds,
# not round numbers - a desktop ISO working tree + output lands in the low
# tens of GB, QEMU guests take 2 GB each, squashfs appreciates RAM.
# Failing here would strand users who only ever build core (~1 GB out);
# warning loudly is the honest middle.
FREE_GB="$(df -BG --output=avail "${REPO_ROOT}" 2>/dev/null | tail -1 | tr -dc '0-9')"
MEM_GB="$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}')"
NPROC_VAL="$(nproc 2>/dev/null || echo 1)"
log_info "Resources: disk ${FREE_GB:-?} GB free, RAM ${MEM_GB:-?} GB, CPUs ${NPROC_VAL}"
if [[ -n "${FREE_GB}" && "${FREE_GB}" -lt 20 ]]; then
    log_warn "Disk under 20 GB free - core builds fit, desktop/gaming working trees may not. Free space or build core only."
fi
if [[ -n "${MEM_GB}" && "${MEM_GB}" -lt 8 ]]; then
    log_warn "Under 8 GB RAM - QEMU boot tests (2 GB each) plus a build will squeeze. Close browsers, or expect slowness."
fi
if [[ "${NPROC_VAL}" -lt 4 ]]; then
    log_warn "Under 4 CPUs - builds work, slowly. Use --jobs to match what exists."
fi
if ! have_cmd gum; then
    log_info "Installing gum (prompt UI)..."
    if sudo_log apt-get update \
        && sudo_log apt-get install -y gum; then
        step_ok "gum installed"
    else
        step_fail "Could not install gum - aborting (no fallback UI by design)."
        exit 1
    fi
else
    step_skip "gum already present"
fi

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] would ensure ${SECRETS_DIR}/ exists (700)"
else
    mkdir -p "${SECRETS_DIR}"
    chmod 700 "${SECRETS_DIR}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 1: APT base tooling (union of both CI workflows' proven dep lists)
# ---------------------------------------------------------------------------
log_step "Step 1/8 - Base build tooling"
APT_PKGS=(
    live-build debootstrap xorriso squashfs-tools jq gpg
    qemu-system-x86 ovmf p7zip-full mmdebstrap buildah skopeo
    git rsync curl ca-certificates gnupg shellcheck gh
    qemu-kvm libvirt-daemon-system debian-archive-keyring
    netavark aardvark-dns
)
MISSING_PKGS=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "${pkg}" > /dev/null 2>&1 || MISSING_PKGS+=("${pkg}")
done
if [[ "${#MISSING_PKGS[@]}" -eq 0 ]]; then
    step_skip "all ${#APT_PKGS[@]} base packages installed"
else
    log_info "Installing: ${MISSING_PKGS[*]}"
    if sudo_log apt-get update \
        && sudo_log apt-get install -y "${MISSING_PKGS[@]}"; then
        step_ok "base packages installed (${#MISSING_PKGS[@]} new)"
    else
        step_fail "apt install failed - see ${LOG_FILE}."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: pinned tools (same versions + checksums CI uses)
# ---------------------------------------------------------------------------
log_step "Step 2/8 - Pinned supply-chain tools"
install_pinned_tgz() {
    local name="${1}" ver="${2}" base_url="${3}" bin="${4}" expect_sha="${5}"
    if have_cmd "${bin}" && "${bin}" version 2>/dev/null | grep -q "${ver}"; then
        step_skip "${name} ${ver} already installed"
        return 0
    fi
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would download+verify+install ${name} ${ver} (have: $(have_cmd "${bin}" && echo yes || echo no))"
        return 0
    fi
    local tgz="/tmp/${name}-${ver}.tgz"
    log_run curl -sL --max-time 120 -o "${tgz}" "${base_url}"
    echo "${expect_sha}  ${tgz}" | sha256sum -c - >> "${LOG_FILE}" 2>&1 \
        || { step_fail "${name} checksum mismatch - refusing to install."; return 1; }
    sudo_log tar -xzf "${tgz}" -C /usr/local/bin "${bin}"
    rm -f "${tgz}"
    rm -f "${tgz}"
    step_ok "${name} ${ver} installed"
}
# NOTE: re-pin deliberately when CI moves (see container-build.yml) - the
# checksums below must match that file's, or local and CI diverge silently.
install_pinned_tgz "syft" "1.52.0" \
    "https://github.com/anchore/syft/releases/download/v1.52.0/syft_1.52.0_linux_amd64.tar.gz" \
    "syft" "caeedb81fb0491615f1ebd1761e4145d41ee86dd2cc7bf80669f9f5ad9d6133d" || true
install_pinned_tgz "grype" "0.119.0" \
    "https://github.com/anchore/grype/releases/download/v0.119.0/grype_0.119.0_linux_amd64.tar.gz" \
    "grype" "3fa2dc4b924621ab65404cf08d0b8438d896d80ab949c9d5a4ca283c36004c9b" || true
# cosign ships as a raw binary, not a tarball - separate path, same
# checksum discipline.
if have_cmd cosign && cosign version 2>/dev/null | grep -q "3.1.3"; then
    step_skip "cosign 3.1.3 already installed"
elif [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] would download+verify+install cosign 3.1.3 (have: $(have_cmd cosign && echo yes || echo no))"
else
    COSIGN_SHA="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
    if log_run curl -sL --max-time 120 -o /tmp/cosign https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-linux-amd64 \
        && echo "${COSIGN_SHA}  /tmp/cosign" | sha256sum -c - >> "${LOG_FILE}" 2>&1 \
        && sudo_log install -m 0755 /tmp/cosign /usr/local/bin/cosign; then
        step_ok "cosign 3.1.3 installed"
    else
        step_fail "cosign install failed (checksum or download)."
    fi
    rm -f /tmp/cosign
fi
log_info "If any install failed above, re-run after fixing network/apt - versions stay pinned."

# ---------------------------------------------------------------------------
# Step 3: KVM/libvirt + groups (re-login notice is load-bearing)
# ---------------------------------------------------------------------------
log_step "Step 3/8 - KVM and libvirt"
if [[ -e /dev/kvm ]]; then
    step_ok "/dev/kvm present"
else
    step_fail "/dev/kvm missing - KVM unavailable (enable virtualization in firmware)."
fi
for grp in kvm libvirt; do
    if id -nG "$(id -un)" | grep -qw "${grp}"; then
        step_skip "already in '${grp}' group"
    elif [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] would add user to '${grp}' (re-login required after)"
    elif sudo_log usermod -aG "${grp}" "$(id -un)"; then
        log_warn "Added to '${grp}' - LOG OUT AND BACK IN for it to take effect."
    else
        step_fail "Could not add user to '${grp}'."
    fi
done

# ---------------------------------------------------------------------------
# Step 4: gh auth (guided - credentials never touch disk via this script)
# ---------------------------------------------------------------------------
log_step "Step 4/8 - GitHub CLI auth"
if gh auth status >> "${LOG_FILE}" 2>&1; then
    step_skip "gh already authenticated"
elif [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] would launch interactive gh login"
elif [[ "${OPT_UNATTENDED}" -eq 1 ]]; then
    step_skip "unattended - gh left unauthenticated"
else
    log_info "Launching interactive gh login (browser/device flow)..."
    if gh auth login; then
        step_ok "gh authenticated"
    else
        step_fail "gh login did not complete - rerun this script later to retry."
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: container registry auth (guided, token via pipe only)
# ---------------------------------------------------------------------------
log_step "Step 5/8 - Registry auth (skopeo/docker)"
if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    step_skip "unattended - registry left unauthenticated"
    log_info "[dry-run] would offer: gh-token login / paste token / skip"
elif [[ "${OPT_UNATTENDED}" -eq 1 ]]; then
    step_skip "unattended - registry left unauthenticated"
else
    CHOICE="$(ask_choice "Container registry auth?" "Use gh token (recommended)" "Paste a token" "Skip")"
    case "${CHOICE}" in
        "Use gh token (recommended)")
            if gh auth token 2>/dev/null | skopeo login ghcr.io -u "$(gh api user -q .login 2>/dev/null || echo x)" --password-stdin >> "${LOG_FILE}" 2>&1; then
                step_ok "skopeo logged in to ghcr.io"
            else
                step_fail "skopeo login failed (gh token may lack read:packages)."
            fi
            ;;
        "Paste a token")
            TOKEN="$(gum input --password --header "Registry token (input hidden, never logged)" < /dev/tty)"
            if [[ -n "${TOKEN}" ]]; then
                printf '%s' "${TOKEN}" | skopeo login ghcr.io -u "$(gum input --header "Registry username" --value "$(id -un)" < /dev/tty)" --password-stdin >> "${LOG_FILE}" 2>&1 \
                    && step_ok "skopeo logged in to ghcr.io" \
                    || step_fail "skopeo login failed."
                unset TOKEN
            else
                step_skip "empty token"
            fi
            ;;
        *) step_skip "registry auth" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 6: GPG signing key - import / generate / skip
# ---------------------------------------------------------------------------
log_step "Step 6/8 - GPG signing key (ISO signing)"
write_kv_file() {
    # write_kv_file <path> <KEY=VAL>... : 600 perms, values never logged
    local path="${1}"; shift
    : > "${path}"
    chmod 600 "${path}"
    local kv
    for kv in "$@"; do
        printf '%s\n' "${kv}" >> "${path}"
    done
}
if [[ -f "${SECRETS_DIR}/signing.env" ]] && grep -qE "^OS_GPG_KEY=.+" "${SECRETS_DIR}/signing.env"; then
    step_skip "signing.env already configured"
else
    CHOICE="$(ask_choice "GPG signing key?" "Import public+secret key file" "Generate a new key" "Skip")"
    case "${CHOICE}" in
        "Import public+secret key file")
            KEYFILE="$(gum input --header "Path to exported key file (.asc)" < /dev/tty)"
            if [[ -f "${KEYFILE}" ]] && run_sensitive "gpg --import [REDACTED]" gpg --import "${KEYFILE}"; then
                FPR="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
                write_kv_file "${SECRETS_DIR}/signing.env" "OS_GPG_KEY=${FPR}" "OS_GPG_BATCH=0"
                step_ok "key imported, fingerprint recorded (value in file only, not log)"
            else
                step_fail "key import failed."
            fi
            ;;
        "Generate a new key")
            KEYNAME="$(gum input --header "Key name" --value "Distribution Release Key" < /dev/tty)"
            KEYMAIL="$(gum input --header "Key email" < /dev/tty)"
            if [[ -n "${KEYMAIL}" ]]; then
                BATCH="$(mktemp)"
                printf '%s\n' "Key-Type: RSA" "Key-Length: 4096" "Expire-Date: 10y" "Name-Real: ${KEYNAME}" "Name-Email: ${KEYMAIL}" "%no-protection" "%commit" > "${BATCH}"
                echo "gpg --batch --generate-key [REDACTED batch file]" >> "${LOG_FILE}"
                if gpg --batch --generate-key "${BATCH}" >> "${LOG_FILE}" 2>&1; then
                    FPR="$(gpg --list-secret-keys --with-colons "${KEYMAIL}" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
                    write_kv_file "${SECRETS_DIR}/signing.env" "OS_GPG_KEY=${FPR}" "OS_GPG_BATCH=0"
                    step_ok "key generated (RSA 4096, 10y) - BACK IT UP, it exists nowhere else"
                else
                    step_fail "key generation failed."
                fi
                rm -f "${BATCH}"
            else
                step_skip "empty email"
            fi
            ;;
        *) step_skip "GPG key setup (signing will stay disabled)" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 7: mirror credentials - fill fields / skip
# ---------------------------------------------------------------------------
log_step "Step 7/8 - Mirror credentials (publish.sh)"
if [[ -f "${SECRETS_DIR}/mirror-credentials.env" ]] && grep -qE "^OS_MIRROR_HOST=.+" "${SECRETS_DIR}/mirror-credentials.env"; then
    step_skip "mirror-credentials.env already configured"
else
    CHOICE="$(ask_choice "Mirror credentials?" "Enter fields now" "Skip")"
    if [[ "${CHOICE}" == "Enter fields now" ]]; then
        MHOST="$(gum input --header "OS_MIRROR_HOST" < /dev/tty)"
        MUSER="$(gum input --header "OS_MIRROR_USER" < /dev/tty)"
        MPATH="$(gum input --header "OS_MIRROR_PATH" < /dev/tty)"
        MKEY="$(gum input --header "OS_MIRROR_SSH_KEY (empty = ssh-agent)" < /dev/tty)"
        write_kv_file "${SECRETS_DIR}/mirror-credentials.env" \
            "OS_MIRROR_HOST=${MHOST}" "OS_MIRROR_USER=${MUSER}" \
            "OS_MIRROR_PATH=${MPATH}" "OS_MIRROR_SSH_KEY=${MKEY}"
        step_ok "mirror credentials written (values in file only, not log)"
    else
        step_skip "mirror credentials (publishing stays disabled)"
    fi
fi

# ---------------------------------------------------------------------------
# Step 8: tokens - GitHub token for release automation / skip
# ---------------------------------------------------------------------------
log_step "Step 8/8 - Automation tokens"
if [[ -f "${SECRETS_DIR}/github-token.env" ]] && grep -qE "^OS_GITHUB_TOKEN=gh[pousr]_" "${SECRETS_DIR}/github-token.env"; then
    step_skip "github-token.env already holds a token-shaped value"
else
    CHOICE="$(ask_choice "GitHub automation token?" "Paste token" "Skip")"
    if [[ "${CHOICE}" == "Paste token" ]]; then
        GHT="$(gum input --password --header "Token (input hidden, never logged)" < /dev/tty)"
        if [[ -n "${GHT}" ]]; then
            write_kv_file "${SECRETS_DIR}/github-token.env" \
                "OS_GITHUB_TOKEN=${GHT}" \
                "OS_GITHUB_REPO=fa-saikat/shopno-os" \
                "OS_GITHUB_API_URL=https://api.github.com"
            step_ok "token stored (value in file only, not log)"
            unset GHT
        else
            step_skip "empty token"
        fi
    else
        step_skip "automation token (release automation stays disabled)"
    fi
fi

# ---------------------------------------------------------------------------
# Verify table: every tool, present version or MISSING. Non-zero exit on
# any missing - green means green, same contract as CI.
# ---------------------------------------------------------------------------
log_step "Verification"
ALL_OK=1
for cmd in lb debootstrap xorriso mksquashfs gpg jq curl git rsync mmdebstrap buildah skopeo qemu-system-x86_64 syft grype cosign gh gum virsh; do
    if have_cmd "${cmd}"; then
        VER="$("${cmd}" --version 2>/dev/null | head -1 || echo present)"
        log_info "  OK   ${cmd}: ${VER:0:80}"
    else
        step_fail "  MISSING ${cmd}"
        ALL_OK=0
    fi
done
[[ -e /dev/kvm ]] && log_info "  OK   /dev/kvm present" || { step_fail "  MISSING /dev/kvm"; ALL_OK=0; }

echo ""
log_info "Full log: ${LOG_FILE}"
if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_info "Dry run complete - nothing installed, written, or prompted."
    log_info "Missing tools above are what a real run would install."
    exit 0
fi
if [[ "${ALL_OK}" -eq 1 ]]; then
    log_success "Environment ready - every tool present."
else
    log_error "Environment incomplete - see MISSING lines above and ${LOG_FILE}."
    exit 1
fi
