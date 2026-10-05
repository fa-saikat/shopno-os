#!/usr/bin/env bash
# =============================================================================
# scripts/utils/runner-vm-status.sh
# ShopnoOS - Self-hosted runner VM status via libvirt
#
# USAGE:
#   ./scripts/utils/runner-vm-status.sh [--name VM] [--all]
#
# PURPOSE:
#   Answers "is the builder VM even up, and with what shape" without
#   remembering virsh flags. Shows domain state, vCPU/RAM/disk reality,
#   and the CPU-mode line that decides whether the `kvm` runner label
#   is true (host-passthrough) or a lie (qemu64 -> boot gate falls
#   back to TCG emulation - see infra/terraform/README.md).
#
# OPTIONS:
#   --name VM   Domain name (default: $RUNNER_VM or shopno-iso-builder)
#   --all       Also list every other domain (neighbors at a glance)
#   -h, --help  Show this help
#
# ENV:
#   RUNNER_VM    Default domain name. LIBVIRT_URI selects the hypervisor
#               (default: qemu:///system - the Terraform-managed scope).
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
OPT_ALL=0
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
export LIBVIRT_URI

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --name) VM="${2}"; shift 2 ;;
        --all)  OPT_ALL=1; shift ;;
        -h|--help) _usage 0 ;;
        -*)     log_error "Unknown option: ${1}"; _usage ;;
        *)      log_error "Unexpected positional argument: ${1}"; _usage ;;
    esac
done

require_command virsh

log_step "Domain ${VM} (${LIBVIRT_URI})"
if ! virsh --connect "${LIBVIRT_URI}" dominfo "${VM}"; then
    die "No such domain '${VM}' on ${LIBVIRT_URI}. Try --all to list what exists."
fi

# CPU mode: the line the whole self-hosted story hinges on.
CPU_MODE="$(virsh --connect "${LIBVIRT_URI}" dumpxml "${VM}" \
    | grep -o '<cpu[^>]*mode=['"'"'"][^'"'"'"]*['"'"'"]' | head -1 || true)"
if [[ "${CPU_MODE}" == *"host-passthrough"* ]]; then
    log_success "CPU mode: host-passthrough - nested KVM available, 'kvm' label is true."
else
    log_warn "CPU mode: ${CPU_MODE:-unparsed} - if not host-passthrough, the boot gate runs TCG."
fi

if [[ "${OPT_ALL}" -eq 1 ]]; then
    echo ""
    log_step "All domains"
    virsh --connect "${LIBVIRT_URI}" list --all
fi
