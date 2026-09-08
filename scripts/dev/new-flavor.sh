#!/usr/bin/env bash
# =============================================================================
# scripts/dev/new-flavor.sh
# ShopnoOS - New Flavor Scaffolder
#
# USAGE:
#   ./scripts/dev/new-flavor.sh <flavor-name>
#
# EXAMPLE:
#   ./scripts/dev/new-flavor.sh hyprland
#   ./scripts/dev/new-flavor.sh cinnamon
#
# WHAT IT CREATES:
#   flavors/<n>/
#   ├── README.md
#   ├── package-lists/
#   │   ├── shopno-os-flavor-<n>.list.chroot        (DE + DM packages)
#   │   └── shopno-os-flavor-<n>-apps.list.chroot   (DE-specific apps)
#   ├── config/
#   │   └── includes.chroot
#   │       └── etc/shopno-os/flavor                (contains: "<n>")
#   ├── skel/                                       (→ /etc/skel in chroot)
#   │   └── .config/
#   └── hooks/
#       └── chroot/
#           └── 0010-<n>-setup.hook.chroot
#
# GOLDEN RULE REMINDER:
#   Flavors provide DE/WM + theming ONLY.
#   No capability packages (Xorg, PipeWire, NetworkManager) - those live in editions/desktop.
#   No hardware packages - those live in hardware/.
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
FLAVOR_NAME="${1:-}"

if [[ -z "${FLAVOR_NAME}" ]]; then
    log_error "Usage: $0 <flavor-name>"
    log_error "Example: $0 hyprland"
    exit 1
fi

if ! [[ "${FLAVOR_NAME}" =~ ^[a-z][a-z0-9\-]*$ ]]; then
    log_error "Flavor name '${FLAVOR_NAME}' is invalid."
    log_error "  Must be: lowercase letters, digits, hyphens. No spaces. No uppercase."
    exit 1
fi

FLAVOR_DIR="${OS_REPO_ROOT}/flavors/${FLAVOR_NAME}"

if [[ -d "${FLAVOR_DIR}" ]]; then
    log_error "Flavor already exists: ${FLAVOR_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Scaffold
# ---------------------------------------------------------------------------
log_step "Scaffolding flavor: ${FLAVOR_NAME}"

mkdir -p \
    "${FLAVOR_DIR}/package-lists" \
    "${FLAVOR_DIR}/config/includes.chroot/etc/${ISO_PREFIX}" \
    "${FLAVOR_DIR}/skel/.config" \
    "${FLAVOR_DIR}/hooks/chroot"

# --- flavor identifier -------------------------------------------------------
echo "${FLAVOR_NAME}" > "${FLAVOR_DIR}/config/includes.chroot/etc/${ISO_PREFIX}/flavor"
log_info "Created: config/includes.chroot/etc/${ISO_PREFIX}/flavor"

# --- main package list -------------------------------------------------------
cat > "${FLAVOR_DIR}/package-lists/${ISO_PREFIX}-flavor-${FLAVOR_NAME}.list.chroot" <<EOF
# =============================================================================
# ${ISO_PREFIX}-flavor-${FLAVOR_NAME}.list.chroot
# Layer:   flavors/${FLAVOR_NAME}
# Purpose: DE/WM core packages for the '${FLAVOR_NAME}' flavor
#
# SCOPE - this file should contain ONLY:
#   - The display manager (gdm3, sddm, lightdm, etc.)
#   - The DE/WM itself and its core components
#   - Theming packages specific to this DE/WM
#   - Session management packages
#
# NEVER PUT HERE:
#   - Xorg / Wayland compositors (→ editions/desktop)
#   - PipeWire / PulseAudio     (→ editions/desktop)
#   - NetworkManager            (→ editions/desktop)
#   - Hardware drivers          (→ hardware/)
#   - Generic productivity apps (→ editions/desktop or editions/pro)
# =============================================================================

# TODO: Add the DE/WM core packages for '${FLAVOR_NAME}' below
# Example for a hypothetical flavor:
#   ${FLAVOR_NAME}-session
#   ${FLAVOR_NAME}-common
#   some-display-manager

EOF
log_info "Created: package-lists/${ISO_PREFIX}-flavor-${FLAVOR_NAME}.list.chroot"

# --- apps package list -------------------------------------------------------
cat > "${FLAVOR_DIR}/package-lists/${ISO_PREFIX}-flavor-${FLAVOR_NAME}-apps.list.chroot" <<EOF
# =============================================================================
# ${ISO_PREFIX}-flavor-${FLAVOR_NAME}-apps.list.chroot
# Layer:   flavors/${FLAVOR_NAME}
# Purpose: DE-specific app replacements/additions for '${FLAVOR_NAME}'
#
# Use this list for apps that are DE-specific variants of general apps:
#   e.g. nautilus instead of thunar for GNOME, dolphin instead for KDE.
#
# Generic apps (browsers, office suites) belong in editions/desktop/,
# NOT here - unless they require DE-specific integration to function properly.
# =============================================================================

# TODO: Add DE-specific app packages below

EOF
log_info "Created: package-lists/${ISO_PREFIX}-flavor-${FLAVOR_NAME}-apps.list.chroot"

# --- stub hook ---------------------------------------------------------------
cat > "${FLAVOR_DIR}/hooks/chroot/0010-${FLAVOR_NAME}-setup.hook.chroot" <<EOF
#!/bin/bash
# =============================================================================
# 0010-${FLAVOR_NAME}-setup.hook.chroot
# Layer:   flavors/${FLAVOR_NAME}
# Stage:   chroot
# Purpose: Post-install setup for the '${FLAVOR_NAME}' flavor
# =============================================================================
set -euo pipefail

echo ">>> [${FLAVOR_NAME}/0010-setup] Starting..."

# TODO: Add flavor-specific setup here
# Common tasks:
#   - Enable the display manager:
#     systemctl enable <display-manager>.service
#   - Set the default session:
#     update-alternatives --set x-session-manager /usr/bin/<wm>
#   - Apply dconf/gsettings defaults:
#     dbus-launch gsettings set ...
#   - Install icon theme, cursor theme
#   - Set default applications

echo ">>> [${FLAVOR_NAME}/0010-setup] Done."
EOF
chmod +x "${FLAVOR_DIR}/hooks/chroot/0010-${FLAVOR_NAME}-setup.hook.chroot"
log_info "Created: hooks/chroot/0010-${FLAVOR_NAME}-setup.hook.chroot"

# --- skel placeholder --------------------------------------------------------
touch "${FLAVOR_DIR}/skel/.config/.gitkeep"
log_info "Created: skel/.config/ (add DE dotfiles here → injected to /etc/skel)"

# --- README ------------------------------------------------------------------
cat > "${FLAVOR_DIR}/README.md" <<EOF
# Flavor: \`${FLAVOR_NAME}\`

## What This Flavor Provides

> TODO: Describe the DE/WM this flavor provides and what makes it distinct.

## Scope

This flavor provides **only** the desktop experience layer:
- The \`${FLAVOR_NAME}\` display environment / window manager
- Its display manager
- DE-specific theming and app variants

Everything else (Xorg/Wayland, PipeWire, NetworkManager, base apps) comes
from the \`desktop\` or \`pro\` edition.

## Package Lists

| File | Contents |
|---|---|
| \`${ISO_PREFIX}-flavor-${FLAVOR_NAME}.list.chroot\` | DE/WM core + display manager |
| \`${ISO_PREFIX}-flavor-${FLAVOR_NAME}-apps.list.chroot\` | DE-specific app replacements |

## Skel

Files in \`skel/\` are injected into \`/etc/skel\` in the chroot, providing
default dotfiles/config for new users.

| Path | Purpose |
|---|---|
| \`.config/\` | DE configuration defaults |

## Compatible Editions

This flavor is designed to be paired with:
- \`desktop\` - general-purpose workstation
- \`pro\` - developer workstation

**Not compatible** with: \`core\` (TTY only)

## Build Command

\`\`\`bash
./scripts/build/build.sh ${ISO_PREFIX}-desktop-${FLAVOR_NAME}
./scripts/build/build.sh ${ISO_PREFIX}-pro-${FLAVOR_NAME}
\`\`\`
EOF
log_info "Created: README.md"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_success "Flavor '${FLAVOR_NAME}' scaffolded at: ${FLAVOR_DIR}"

echo ""
echo -e "${CLR_BOLD}Next steps:${CLR_RESET}"
echo "  1. Add DE/WM packages to:"
echo "       flavors/${FLAVOR_NAME}/package-lists/${ISO_PREFIX}-flavor-${FLAVOR_NAME}.list.chroot"
echo ""
echo "  2. Register '${FLAVOR_NAME}' in the valid flavors list:"
echo "       scripts/lib/profile.sh  →  _VALID_FLAVORS array"
echo ""
echo "  3. Create profiles to build with this flavor:"
echo "       ./scripts/dev/new-profile.sh ${ISO_PREFIX}-desktop-${FLAVOR_NAME}"
echo "       ./scripts/dev/new-profile.sh ${ISO_PREFIX}-pro-${FLAVOR_NAME}"
echo ""
echo "  4. Add display manager enable to the setup hook:"
echo "       flavors/${FLAVOR_NAME}/hooks/chroot/0010-${FLAVOR_NAME}-setup.hook.chroot"
echo ""
echo "  5. Run lint to verify no package conflicts:"
echo "       ./scripts/dev/lint-packages.sh"
