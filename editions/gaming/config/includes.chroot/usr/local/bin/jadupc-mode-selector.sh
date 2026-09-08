#!/usr/bin/env bash
# /usr/bin/jadupc-mode-selector
# Wrapper for the JaduPC Mode Selector Python daemon.
#
# If the daemon is already running (e.g. hidden after a mode launch),
# sends SIGUSR1 to surface it and exits immediately without opening
# a second instance.

set -euo pipefail

SCRIPT_DIR="/usr/local/share/jadupc-mode-selector"
PYTHON_APP="${SCRIPT_DIR}/app.py"
PID_FILE="${XDG_RUNTIME_DIR}/jadupc/mode-selector.pid"
WELCOME_FLAG="${XDG_CONFIG_HOME}/jadupc/welcome-autostart"

_kill_mode_procs() {
    # emulationstation
    if pgrep -f "xfce4-terminal.*emulationstation" > /dev/null 2>&1; then
        # echo "jadupc-mode-selector: stopping emulationstation"
        pkill -TERM -f "xfce4-terminal.*emulationstation" || true
        sleep 1
        pkill -KILL f "xfce4-terminal.*emulationstation" 2>/dev/null || true
    fi

    # firefox
    # --kiosk flag so we don't kill a regular
    # browser the user might have open in Desktop mode
    if pgrep -f "chrome.*--kiosk" > /dev/null 2>&1; then
        echo "jadupc-mode-selector: stopping kodi"
        pkill -TERM -f "chrome.*--kiosk" || true
        sleep 1
        pkill -KILL -f "chrome.*--kiosk" 2>/dev/null || true
    fi

    if pgrep -f "kodi" > /dev/null 2>&1; then
        echo "jadupc-mode-selector: stopping kodi"
        pkill -TERM -f "kodi" || true
        sleep 1
        pkill -KILL -f "kodi" 2>/dev/null || true
    fi
}

: "${DISPLAY:=:0}"
export DISPLAY

# For Wayland sessiosn
if [[ -z "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR}/wayland-0" ]]; then
    export WAYLAND_DISPLAY=wayland-0
fi

HW_PROFILE_FILE="/run/user/${UID}/jadupc/hw-profile"
if [[ -f "${HW_PROFILE_FILE}" ]]; then
    hw_profile="$(cat "${HW_PROFILE_FILE}")"
    overrides="/opt/jadupc/hardware/${hw_profile}/overrides.env"
    if [[ -f "${overrides}" ]]; then
        # shellcheck source=/dev/null
        set -a; source "${overrides}"; set +a
    fi
fi

[[ -d "${XDG_RUNTIME_DIR}/jadupc" ]] || mkdir -p "${XDG_RUNTIME_DIR}/jadupc"


if [[ -f "${PID_FILE}" ]]; then
    existing_pid="$(cat "${PID_FILE}")"
    if kill -0 "${existing_pid}" 2>/dev/null; then
        kill -USR1 "${existing_pid}"
        _kill_mode_procs
        exit 0
    else
        # Stale PID file from a previous crash — remove and continue to launch
        rm -f "${PID_FILE}"
    fi
fi

if [[ -f "${WELCOME_FLAG}" ]]; then
    rm -f "${WELCOME_FLAG}"
    /usr/bin/jadupc-welcome || true
fi

exec python3 "${PYTHON_APP}"
