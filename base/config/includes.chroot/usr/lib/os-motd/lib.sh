# shellcheck shell=bash
# shellcheck disable=SC2034  # globals set here are read by the edition themes
# =============================================================================
# /usr/lib/os-motd/lib.sh  (layer: base)
#
# Shared helpers for the login greeting. Sourced by /etc/update-motd.d/10-welcome
# and by the edition theme at /usr/lib/os-motd/theme.sh (if the edition ships one).
#
# Nothing edition-specific lives here, and nothing brand-specific either:
# identity is read from /etc/os-release at runtime.
#
# Runs on every login via pam_motd, so: no network, no apt, nothing slow.
# Deliberately no `set -e` — a missing sensor must never eat the greeting.
# =============================================================================

motd_init() {
    local f=/etc/os-release
    [ -r "$f" ] || f=/usr/lib/os-release
    # shellcheck disable=SC1090
    [ -r "$f" ] && . "$f"
    OS_NAME=${NAME:-Linux}
    OS_VER=${VERSION_ID:-}
    OS_CODE=${VERSION_CODENAME:-}

    # pam_motd runs us as root under `env -i`, output cached in /run/motd.dynamic.
    # `os-welcome` sets MOTD_MODE=cli — then we know the user and the tty.
    MOTD_USER=
    MOTD_COLOR=1
    if [ "${MOTD_MODE:-}" = cli ]; then
        MOTD_USER=${USER:-$(id -un 2>/dev/null)}
        { [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; } || MOTD_COLOR=0
    fi

    MOTD_LIVE=0
    grep -qw 'boot=live' /proc/cmdline 2>/dev/null && MOTD_LIVE=1
}

# --- colour ------------------------------------------------------------------
# 256-colour codes: the Linux VT maps them down to 16, terminals use them as-is.
fg()    { [ "$MOTD_COLOR" = 1 ] && printf '\033[38;5;%sm' "$1"; return 0; }
bold()  { [ "$MOTD_COLOR" = 1 ] && printf '\033[1m';  return 0; }
blink() { [ "$MOTD_COLOR" = 1 ] && printf '\033[5m';  return 0; }
rst()   { [ "$MOTD_COLOR" = 1 ] && printf '\033[0m';  return 0; }

# --- stats -------------------------------------------------------------------
motd_uptime_s() { local u; read -r u _ < /proc/uptime; echo "${u%.*}"; }

# "3h 12m", "2d 4h", "8m"
motd_uptime_short() {
    local s=$1 d h m
    d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
    elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
    else                      echo "${m}m"
    fi
}

# "03:12:44" (hours roll past 24 on purpose)
motd_uptime_clock() {
    local s=$1
    printf '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

motd_load1() { local l; read -r l _ < /proc/loadavg; echo "$l"; }

# Sets MEM_TOTAL_KB, MEM_AVAIL_KB
motd_mem() {
    local k v
    MEM_TOTAL_KB=0 MEM_AVAIL_KB=0
    while read -r k v _; do
        case $k in
            MemTotal:)     MEM_TOTAL_KB=$v ;;
            MemAvailable:) MEM_AVAIL_KB=$v ;;
        esac
    done < /proc/meminfo
}

# Sets DISK_TOTAL_KB, DISK_AVAIL_KB for $1 (default /)
motd_disk() {
    local line
    line=$(df -Pk "${1:-/}" 2>/dev/null | awk 'NR==2 {print $2, $4}')
    read -r DISK_TOTAL_KB DISK_AVAIL_KB <<< "${line:-0 0}"
}

# kB -> "15.6G" / "512M"
motd_human_kb() {
    awk -v k="$1" 'BEGIN {
        if (k >= 1048576) printf "%.1fG", k / 1048576
        else              printf "%dM",   k / 1024 }'
}

motd_pct() { [ "${2:-0}" -gt 0 ] && echo $(( $1 * 100 / $2 )) || echo 0; }

# CPU package temperature in °C, empty if no sensor. hwmon first (k10temp,
# coretemp are hwmon-only on many boards), thermal zones as fallback.
motd_temp_c() {
    local d n t best=
    for d in /sys/class/hwmon/hwmon*; do
        read -r n 2>/dev/null < "$d/name" || continue
        case $n in
            k10temp|coretemp|zenpower|cpu_thermal)
                read -r t 2>/dev/null < "$d/temp1_input" && { echo $((t / 1000)); return; } ;;
        esac
    done
    for d in /sys/class/thermal/thermal_zone*; do
        read -r t 2>/dev/null < "$d/temp" || continue
        { [ -z "$best" ] || [ "$t" -gt "$best" ]; } && best=$t
    done
    [ -n "$best" ] && echo $((best / 1000))
}

motd_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# Same item all day, a different one tomorrow: motd_pick_daily "a" "b" "c"
motd_pick_daily() {
    local i=$(( 10#$(date +%j) % $# + 1 ))
    printf '%s' "${!i}"
}

# motd_bar <pct> <width> <fill-char> <empty-char> <fill-colour> <empty-colour>
motd_bar() {
    local pct=$1 w=$2 on=$3 off=$4 c_on=$5 c_off=$6 n i
    [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
    n=$(( (pct * w + 50) / 100 ))
    fg "$c_on";  for ((i = 0; i < n; i++));  do printf '%s' "$on";  done
    fg "$c_off"; for ((i = n; i < w; i++)); do printf '%s' "$off"; done
    rst
}

# --- fallback (core, kiosk, or any edition without a theme) ---------------
motd_plain() {
    local up
    up=$(motd_uptime_short "$(motd_uptime_s)")
    motd_mem; motd_disk /
    echo
    printf '  %s%s %s%s %s\n' "$(bold)" "$OS_NAME" "$OS_VER" "$(rst)" "${OS_CODE:+($OS_CODE)}"
    printf '  up %s · load %s · mem %s free · / %s free\n' \
        "$up" "$(motd_load1)" "$(motd_human_kb "$MEM_AVAIL_KB")" "$(motd_human_kb "$DISK_AVAIL_KB")"
    [ "$MOTD_LIVE" = 1 ] && printf '  live session — changes are not saved\n'
    echo
}
