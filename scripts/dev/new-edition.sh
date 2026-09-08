#!/usr/bin/env bash
# =============================================================================
# scripts/dev/new-edition.sh
# ShopnoOS - New Edition Scaffolder
#
# USAGE:
#   ./scripts/dev/new-edition.sh <edition-name>
#
# EXAMPLE:
#   ./scripts/dev/new-edition.sh gaming
#   ./scripts/dev/new-edition.sh security
#
# WHAT IT CREATES:
#   editions/<name>/
#   ├── README.md
#   ├── package-lists/
#   │   └── shopno-os-<name>.list.chroot         (stub)
#   ├── config/
#   │   └── includes.chroot
#   │       └── etc/shopno-os/edition            (contains: "<name>")
#   └── hooks/
#       └── chroot/
#           └── 0010-<name>-setup.hook.chroot (stub)
#
# NEXT STEPS (printed at end):
#   1. Add packages to editions/<name>/package-lists/
#   2. Create a profile: ./scripts/dev/new-profile.sh shopno-os-<name>-<flavor>
#   3. Register '<name>' in scripts/lib/profile.sh _VALID_EDITIONS array
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
EDITION_NAME="${1:-}"

if [[ -z "${EDITION_NAME}" ]]; then
    log_error "Usage: $0 <edition-name>"
    log_error "Example: $0 gaming"
    exit 1
fi

# Validate name: lowercase letters, digits, hyphens
if ! [[ "${EDITION_NAME}" =~ ^[a-z][a-z0-9\-]*$ ]]; then
    log_error "Edition name '${EDITION_NAME}' is invalid."
    log_error "  Must be: lowercase letters, digits, hyphens. No spaces. No uppercase."
    exit 1
fi

EDITION_DIR="${OS_REPO_ROOT}/editions/${EDITION_NAME}"

if [[ -d "${EDITION_DIR}" ]]; then
    log_error "Edition already exists: ${EDITION_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Scaffold
# ---------------------------------------------------------------------------
log_step "Scaffolding edition: ${EDITION_NAME}"

mkdir -p \
    "${EDITION_DIR}/package-lists" \
    "${EDITION_DIR}/config/includes.chroot/etc/shopno-os" \
    "${EDITION_DIR}/hooks/chroot"

# --- edition identifier file ------------------------------------------------
echo "${EDITION_NAME}" > "${EDITION_DIR}/config/includes.chroot/etc/shopno-os/edition"
log_info "Created: config/includes.chroot/etc/shopno-os/edition"

# --- stub package list -------------------------------------------------------
cat > "${EDITION_DIR}/package-lists/shopno-os-${EDITION_NAME}.list.chroot" <<EOF
# =============================================================================
# shopno-os-${EDITION_NAME}.list.chroot
# Layer:   editions/${EDITION_NAME}
# Purpose: Core packages for the '${EDITION_NAME}' edition
#
# RULES:
#   - Do NOT add packages that belong in base/ (kernel, systemd, apparmor)
#   - Do NOT add DE/WM packages - those belong in flavors/
#   - Do NOT add hardware driver packages - those belong in hardware/
#   - Each package listed here must justify its presence in this edition
# =============================================================================

# TODO: Add packages for the '${EDITION_NAME}' edition below

EOF
log_info "Created: package-lists/shopno-os-${EDITION_NAME}.list.chroot"

# --- stub chroot hook --------------------------------------------------------
cat > "${EDITION_DIR}/hooks/chroot/0010-${EDITION_NAME}-setup.hook.chroot" <<EOF
#!/bin/bash
# =============================================================================
# 0010-${EDITION_NAME}-setup.hook.chroot
# Layer:   editions/${EDITION_NAME}
# Stage:   chroot
# Purpose: Initial setup hook for the '${EDITION_NAME}' edition
# Number:  0010 - runs first; add later numbered hooks for additional steps
# =============================================================================
set -euo pipefail

echo ">>> [${EDITION_NAME}/0010-setup] Starting..."

# TODO: Add edition-specific setup here
# Examples:
#   systemctl enable some-service.service
#   update-alternatives --set ...
#   sed -i 's/old/new/' /etc/some/config

echo ">>> [${EDITION_NAME}/0010-setup] Done."
EOF
chmod +x "${EDITION_DIR}/hooks/chroot/0010-${EDITION_NAME}-setup.hook.chroot"
log_info "Created: hooks/chroot/0010-${EDITION_NAME}-setup.hook.chroot"

# --- README ------------------------------------------------------------------
cat > "${EDITION_DIR}/README.md" <<EOF
# Edition: \`${EDITION_NAME}\`

## What This Edition Is

> TODO: Describe what this edition is, who it's for, and what capability it adds.

## What It Includes

> TODO: List the key packages and capabilities this edition provides.

## What It Deliberately Excludes

| Excluded | Reason |
|---|---|
| Desktop environment / WM | Flavor layer responsibility |
| Hardware drivers | Hardware layer responsibility |
| *Add rows as appropriate* | |

## Target Use Cases

> TODO: Who is this edition for?

## Build Command

\`\`\`bash
# First create a profile, then:
./scripts/build/build.sh shopno-os-${EDITION_NAME}-<flavor>
\`\`\`

## Package Lists

| File | Contents |
|---|---|
| \`shopno-os-${EDITION_NAME}.list.chroot\` | Core edition packages |

## Hooks

| Hook | Stage | Purpose |
|---|---|---|
| \`0010-${EDITION_NAME}-setup.hook.chroot\` | chroot | Initial edition setup |
EOF
log_info "Created: README.md"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_success "Edition '${EDITION_NAME}' scaffolded at: ${EDITION_DIR}"

echo ""
echo -e "${CLR_BOLD}Next steps:${CLR_RESET}"
echo "  1. Add packages to:"
echo "       editions/${EDITION_NAME}/package-lists/shopno-os-${EDITION_NAME}.list.chroot"
echo ""
echo "  2. Register '${EDITION_NAME}' in the valid editions list:"
echo "       scripts/lib/profile.sh  →  _VALID_EDITIONS array"
echo ""
echo "  3. Create a profile to build it:"
echo "       ./scripts/dev/new-profile.sh shopno-os-${EDITION_NAME}-gnome"
echo ""
echo "  4. Run lint to verify no package conflicts:"
echo "       ./scripts/dev/lint-packages.sh"
