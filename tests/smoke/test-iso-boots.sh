#!/usr/bin/env bash
# =============================================================================
# tests/smoke/test-iso-boots.sh
# ShopnoOS - Automated Boot Gate
#
# PURPOSE:
#   Boots a built ISO headlessly under QEMU (UEFI/OVMF by default, matching
#   the grub.cfg serial console fix) and verifies it reaches a clean
#   multi-user state via a marker service (base/config/includes.chroot/etc/
#   systemd/system/shopno-os-boot-marker.service).
#
#   NOTE: This tests the UEFI (grub-efi) boot path only. The legacy-BIOS
#   path (isolinux/syslinux) has NOT been serial-configured yet, a SERIAL
#   directive is still needed in base/config/bootloaders/isolinux/ and
#   syslinux/ before --bios legacy will produce a usable log. Booting
#   without --uefi-vars set correctly falls back to SeaBIOS + ISOLINUX,
#   which will currently hang silently waiting for keyboard input on a
#   console nothing is feeding.
#
# USAGE:
#   ./tests/smoke/test-iso-boots.sh <path/to/iso> [options]
#
# OPTIONS:
#   --timeout N       Seconds to wait for boot before giving up (default: 300)
#   --memory M        RAM in MB for the QEMU guest (default: 2048)
#   --keep-log        Don't delete the captured serial log on exit
#   --ovmf-code PATH  Override auto-detected OVMF_CODE*.fd path
#   --ovmf-vars PATH  Override auto-detected OVMF_VARS*.fd template path
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../scripts/lib"

# shellcheck source=../../scripts/lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISO_PATH="${1:-}"
OPT_TIMEOUT=90
OPT_MEMORY=2048
OPT_KEEP_LOG=0
OPT_OVMF_CODE=""
OPT_OVMF_VARS=""

_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <path/to/iso> [options]

Options:
  --timeout N       Seconds to wait for boot before giving up (default: 300)
  --memory M        RAM in MB for the QEMU guest (default: 2048)
  --keep-log        Don't delete the captured serial log on exit
  --ovmf-code PATH  Override auto-detected OVMF_CODE*.fd path
  --ovmf-vars PATH  Override auto-detected OVMF_VARS*.fd template path
  -h, --help        Show this help
EOF
    exit 1
}

# Options taking values consume the next token blindly - without this guard
# a typo like `--timeout --keep-logs` silently stuffs the flag name into
# OPT_TIMEOUT and detonates pages later as `keep: unbound variable` inside
# arithmetic, long after QEMU launched. Fail here instead, with the cause.
_require_number() {
    local flag="${1}"
    local value="${2}"
    if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
        log_error "${flag} expects a numeric value, got: '${value}'"
        _usage
    fi
}

[[ -z "${ISO_PATH}" ]] && _usage
shift || true

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --timeout)   _require_number "--timeout" "${2:-}"; OPT_TIMEOUT="${2}"; shift ;;
        --memory)    _require_number "--memory" "${2:-}"; OPT_MEMORY="${2}"; shift ;;
        --keep-log)  OPT_KEEP_LOG=1 ;;
        --ovmf-code) OPT_OVMF_CODE="${2:-}"; shift ;;
        --ovmf-vars) OPT_OVMF_VARS="${2:-}"; shift ;;
        -h|--help)   _usage ;;
        *) log_error "Unknown option: ${1}"; _usage ;;
    esac
    shift
done

require_file "${ISO_PATH}"
require_command qemu-system-x86_64

# ---------------------------------------------------------------------------
# Locate OVMF firmware (UEFI boot - required to exercise the grub-efi path)
# ---------------------------------------------------------------------------
if [[ -z "${OPT_OVMF_CODE}" ]]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd
    do
        [[ -f "${candidate}" ]] && { OPT_OVMF_CODE="${candidate}"; break; }
    done
fi
if [[ -z "${OPT_OVMF_VARS}" ]]; then
    for candidate in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd
    do
        [[ -f "${candidate}" ]] && { OPT_OVMF_VARS="${candidate}"; break; }
    done
fi

if [[ -z "${OPT_OVMF_CODE}" || -z "${OPT_OVMF_VARS}" ]]; then
    log_error "OVMF firmware not found. Install it (e.g. 'apt install ovmf') or pass"
    log_error "  --ovmf-code / --ovmf-vars explicitly. Search with:"
    log_error "    dpkg -L ovmf | grep -i '\\.fd\$'"
    exit 1
fi

log_info "OVMF code: ${OPT_OVMF_CODE}"
log_info "OVMF vars: ${OPT_OVMF_VARS} (template - copied, never written in place)"

# OVMF_VARS is a writable NVRAM template - QEMU writes to it, so give every
# run its own private copy rather than mutating the shared system file.
VARS_COPY="$(mktemp /tmp/shopno-os-ovmf-vars.XXXXXX.fd)"
cp "${OPT_OVMF_VARS}" "${VARS_COPY}"

# ---------------------------------------------------------------------------
# KVM acceleration if available - falls back to software emulation (TCG)
# ---------------------------------------------------------------------------
declare -a ACCEL_ARGS=()
if [[ -w /dev/kvm ]]; then
    log_info "KVM acceleration available - using -enable-kvm"
    ACCEL_ARGS=(-enable-kvm -cpu host)
else
    log_warn "KVM not available (/dev/kvm not writable) - falling back to TCG emulation (slower)"
fi

# ---------------------------------------------------------------------------
# Boot the ISO headlessly, capture serial output
# ---------------------------------------------------------------------------
LOG_FILE="$(mktemp /tmp/shopno-os-boot-test.XXXXXX.log)"

QEMU_PID=""
_cleanup_qemu() {
    # No orphaned QEMU squatting /dev/kvm on persistent runners - this is
    # the highest-blast-radius edge case in the file. Called from every
    # EXIT path below and after the poll loop.
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        kill "${QEMU_PID}" 2>/dev/null || true
        wait "${QEMU_PID}" 2>/dev/null || true
    fi
}

if [[ "${OPT_KEEP_LOG}" -eq 0 ]]; then
    trap '_cleanup_qemu; rm -f "${LOG_FILE}" "${VARS_COPY}"' EXIT
else
    trap '_cleanup_qemu; rm -f "${VARS_COPY}"; log_info "Boot log kept at: ${LOG_FILE}"' EXIT
fi

log_step "Booting ISO under QEMU (UEFI): $(basename "${ISO_PATH}")"
log_info "  Timeout : ${OPT_TIMEOUT}s"
log_info "  Memory  : ${OPT_MEMORY}MB"
log_info "  Log     : ${LOG_FILE}"

QEMU_PID=""
qemu-system-x86_64 \
    -m "${OPT_MEMORY}" \
    -smp 2 \
    "${ACCEL_ARGS[@]}" \
    -drive if=pflash,format=raw,readonly=on,file="${OPT_OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${VARS_COPY}" \
    -cdrom "${ISO_PATH}" \
    -boot d \
    -nographic \
    -serial file:"${LOG_FILE}" \
    -monitor none \
    -no-reboot \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    > /dev/null 2>&1 &
QEMU_PID=$!
log_info "  QEMU pid  : ${QEMU_PID}"

# Poll for the verdict instead of waiting out the timeout: the guest never
# shuts down, so foreground-timeout always consumed the full budget even
# when the marker printed in minutes. --timeout is now purely a cap.
# Detection time is logged - it is the measurement per-edition budgets
# get retuned from (rule of thumb: budget ~= 2x measured).
BOOT_START="${SECONDS}"
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    if grep -q 'CI_BOOT_OK' "${LOG_FILE}" 2>/dev/null; then
        log_info "Marker detected after $((SECONDS - BOOT_START))s (budget ${OPT_TIMEOUT}s) - stopping QEMU"
        break
    fi
    if [[ "$((SECONDS - BOOT_START))" -ge "${OPT_TIMEOUT}" ]]; then
        log_warn "QEMU hit the ${OPT_TIMEOUT}s timeout (this is often expected - the guest has no shutdown trigger)"
        break
    fi
    sleep 10
done
_cleanup_qemu

# ---------------------------------------------------------------------------
# Evaluate the captured log
# ---------------------------------------------------------------------------
# log_step "Boot log tail (last 50 lines)"
# tail -50 "${LOG_FILE}" >&2

FAILED=0

if grep -qi 'kernel panic' "${LOG_FILE}"; then
    log_error "FAIL: kernel panic detected"
    FAILED=1
fi

if ! grep -q 'CI_BOOT_OK' "${LOG_FILE}"; then
    log_error "FAIL: boot marker never printed - system never reached the target it waits on"
    log_error "  Check: is this booting UEFI/grub (has the serial fix) or falling back to"
    log_error "  legacy BIOS/ISOLINUX (does not have a SERIAL directive yet)?"
    FAILED=1
elif ! grep -q 'CI_BOOT_OK running' "${LOG_FILE}"; then
    ACTUAL_STATE="$(grep -o 'CI_BOOT_OK [a-z]*' "${LOG_FILE}" | tail -1)"
    log_error "FAIL: degraded systemd state (${ACTUAL_STATE:-unknown}) - at least one unit failed to start"
    FAILED=1
fi

if [[ "${FAILED}" -eq 1 ]]; then
    log_error "Boot test FAILED: $(basename "${ISO_PATH}")"
    exit 1
fi

log_success "Boot test PASSED: $(basename "${ISO_PATH}")"
exit 0
