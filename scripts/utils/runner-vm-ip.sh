#!/usr/bin/env bash
# =============================================================================
# scripts/utils/runner-vm-ip.sh
# ShopnoOS - Guest IP of the self-hosted runner VM (stale-lease safe)
#
# USAGE:
#   ./scripts/utils/runner-vm-ip.sh [--name VM] [--net NETWORK] [--ssh]
#     [--no-check]
#
# PURPOSE:
#   Prints the runner VM's guest IP on stdout - nothing else - so it
#   composes: `ssh builder@$(./scripts/utils/runner-vm-ip.sh)`.
#   Implements the runbook warning verbatim (infra/terraform/README.md):
#   stale DHCP leases linger, so the domifaddr address is only trusted
#   after its MAC matches `domiflist`. Diagnostics go to stderr.
#
# OPTIONS:
#   --name VM     Domain name (default: $RUNNER_VM or shopno-iso-builder)
#   --net NET     libvirt network for the lease cross-check
#                 (default: $RUNNER_NET or shopno-runner)
#   --ssh         SSH into the guest as builder@$IP instead of printing.
#                 Uses $RUNNER_SSH_KEY (~/.ssh/gh if present) per the
#                 runbook's `ssh -i ~/.ssh/gh builder@<lease-ip>`.
#   --no-check    Skip the MAC cross-check (trust domifaddr blindly)
#   -h, --help    Show this help
#
# ENV:
#   RUNNER_VM, RUNNER_NET, RUNNER_SSH_KEY, RUNNER_SSH_USER (default
#   builder), LIBVIRT_URI (default qemu:///system).
#
# EXIT CODES:
#   0 - IP printed (or SSH exited 0); 1 - VM down, no lease, or MAC mismatch.
#
# PREREQUISITES:
#   virsh (user in the `libvirt` group for qemu:///system).
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

VM="${RUNNER_VM:-shopno-iso-builder}"
NET="${RUNNER_NET:-shopno-runner}"
OPT_SSH=0
OPT_CHECK=1
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
export LIBVIRT_URI

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --name) VM="${2}"; shift 2 ;;
        --net)  NET="${2}"; shift 2 ;;
        --ssh)  OPT_SSH=1; shift ;;
        --no-check) OPT_CHECK=0; shift ;;
        -h|--help) _usage 0 ;;
        -*)     log_error "Unknown option: ${1}"; _usage ;;
        *)      log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command virsh

STATE="$(virsh --connect "${LIBVIRT_URI}" domstate "${VM}" 2>/dev/null || echo missing)"
[[ "${STATE}" == "running" ]] || die "Domain '${VM}' is '${STATE}' - no guest IP to report."

# Guest address per the agent/DHCP table.
LEASE_LINE="$(virsh --connect "${LIBVIRT_URI}" domifaddr "${VM}" 2>/dev/null \
    | awk '$3 == "ipv4" { print $2, $4; exit }' || true)"
[[ -n "${LEASE_LINE}" ]] || die "No ipv4 lease visible for '${VM}' (guest agent/DHCP quiet?)."

LEASE_MAC="${LEASE_LINE%% *}"
LEASE_ADDR="${LEASE_LINE##* }"
IP="${LEASE_ADDR%%/*}"

if [[ "${OPT_CHECK}" -eq 1 ]]; then
    # domiflist MACs are the ground truth: a lease MAC absent here is stale.
    if ! virsh --connect "${LIBVIRT_URI}" domiflist "${VM}" 2>/dev/null | grep -qi "${LEASE_MAC}"; then
        die "Lease MAC ${LEASE_MAC} not in domiflist for '${VM}' - stale lease, refusing ${IP}."
    fi
    # Second opinion from the network's lease table (best effort).
    if ! virsh --connect "${LIBVIRT_URI}" net-dhcp-leases "${NET}" 2>/dev/null | grep -qi "${LEASE_MAC}"; then
        log_warn "MAC ${LEASE_MAC} absent from net-dhcp-leases ${NET} - continuing (domiflist matched)."
    fi
    log_debug "MAC cross-check passed: ${LEASE_MAC} -> ${IP}"
fi

if [[ "${OPT_SSH}" -eq 1 ]]; then
    SSH_USER="${RUNNER_SSH_USER:-builder}"
    SSH_KEY="${RUNNER_SSH_KEY:-${HOME}/.ssh/gh}"
    log_info "SSH ${SSH_USER}@${IP} ..."
    if [[ -f "${SSH_KEY}" ]]; then
        exec ssh -i "${SSH_KEY}" "${SSH_USER}@${IP}"
    else
        log_warn "Key ${SSH_KEY} missing - falling back to default SSH config."
        exec ssh "${SSH_USER}@${IP}"
    fi
fi

echo "${IP}"
