#!/bin/bash
# jadupc-gaming-dnd.sh — enable DND when in gaming mode

set -x

STATE_FILE="/run/user/$(id -u)/jadupc/mode-selector.state"
PID_FILE="/run/user/$(id -u)/jadupc/mode-selector.pid"

_state_is_valid() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null          # is process still alive?
}

_read_state() {
    cat "$STATE_FILE" 2>/dev/null
}

if _state_is_valid && [[ "$(_read_state)" == "0" ]]; then
	pkill chrome
fi

if _state_is_valid && [[ "$(_read_state)" == "3" ]]; then
	if pgrep -f kodi > /dev/null; then
		sleep 3
		notify-send -u critical \
			-i /usr/share/icons/shopno-os.svg \
			-A "key=I Understand!" \
			"JaduPc 3-in-1 HOME" \
			"This is an experimental feature. Bugs and system instability is expected."


		notify-send -u critical \
			-i /usr/share/icons/shopno-os.svg \
			-A "key=I Understand!" \
			"JaduPc 3-in-1 HOME" \
			"Use Mode Selection Menu to exit out of Kodi."
	fi
fi

# if _state_is_valid && [[ "$(_read_state)" == "2" ]]; then
# fi
