# shellcheck shell=bash
# =============================================================================
# /usr/lib/os-motd/theme.sh  (layer: editions/gaming)
#
# Gaming greeting: neon, pixel controller, system stats as a player HUD.
#   HP   = free memory      MP   = free disk
#   HEAT = CPU temperature  TIME = uptime, as "time played"
#   PADS = joysticks seen   LOOT = ROMs in the RetroPie tree
# =============================================================================

# Where to look for ROMs. RetroPie's default is ~/RetroPie/roms; adjust here if
# the gaming edition keeps them elsewhere.
MOTD_ROM_DIRS=(/home/*/RetroPie/roms /opt/retropie/roms)

_motd_roms() {   # prints "<roms> <systems>"
    local base sys n total=0 systems=0
    for base in "${MOTD_ROM_DIRS[@]}"; do
        [ -d "$base" ] || continue
        for sys in "$base"/*/; do
            [ -d "$sys" ] || continue
            n=$(find "$sys" -maxdepth 1 -type f ! -name '.*' \
                    ! -name '*.xml' ! -name '*.txt' ! -name '*.srm' ! -name '*.state*' \
                    2>/dev/null | wc -l)
            [ "$n" -gt 0 ] && { total=$((total + n)); systems=$((systems + 1)); }
        done
    done
    echo "$total $systems"
}

_motd_pads() {
    local n=0 j
    for j in /dev/input/js*; do [ -e "$j" ] && n=$((n + 1)); done
    echo "$n"
}

# green when healthy, yellow when low, red when critical
_motd_level_colour() { if [ "$1" -ge 50 ]; then echo 46; elif [ "$1" -ge 20 ]; then echo 226; else echo 196; fi; }

motd_theme() {
    local mag=201 pur=93 cyn=51 yel=226 grn=46 red=196 dim=240 wht=255

    local secs; secs=$(motd_uptime_s)
    motd_mem; motd_disk /
    local hp mp temp heat_pct heat_c pads roms systems
    hp=$(motd_pct "$MEM_AVAIL_KB" "$MEM_TOTAL_KB")
    mp=$(motd_pct "$DISK_AVAIL_KB" "$DISK_TOTAL_KB")
    temp=$(motd_temp_c)
    pads=$(_motd_pads)
    read -r roms systems <<< "$(_motd_roms)"

    # ---- controller -------------------------------------------------------
    # Art is drawn plain with placeholder letters, then each glyph is recoloured:
    #   ^ v < >  d-pad      =  select/start      g c r y  face buttons
    local B R line
    B=$(fg $pur); R=$(rst)
    local -a pad=(
        "      ▄▄▄▄▄▄▄▄               ▄▄▄▄▄▄▄▄"
        "    ▄█▀▀▀▀▀▀▀▀█▄▄▄▄▄▄▄▄▄▄▄▄▄█▀▀▀▀▀▀▀▀█▄"
        "   ██     ^      =       =      g     ██"
        "   ██   <   >                 c   r   ██"
        "   ██     v                     y     ██"
        "    ▀█▄▄       ▄▄█▀▀▀▀▀▀▀█▄▄       ▄▄█▀"
        "      ▀▀▀▀▀▀▀▀               ▀▀▀▀▀▀▀▀"
    )
    echo
    for line in "${pad[@]}"; do
        line=${line//^/$(fg $cyn)▲$B}
        line=${line//v/$(fg $cyn)▼$B}
        line=${line//</$(fg $cyn)◄$B}
        line=${line//>/$(fg $cyn)►$B}
        line=${line//=/$(fg $dim)▬$B}
        line=${line//g/$(fg $grn)•$B}
        line=${line//c/$(fg $cyn)•$B}
        line=${line//r/$(fg $red)•$B}
        line=${line//y/$(fg $yel)•$B}
        printf '%s%s%s\n' "$B" "$line" "$R"
    done
    echo

    # ---- title ------------------------------------------------------------
    printf '   %s%s%s %s%s\n' "$(bold)" "$(fg $mag)" "${OS_NAME^^}" "$OS_VER" "$R"
    local stage=${OS_CODE:-unknown}
    printf '   %sSTAGE  %s%s%s\n' "$(fg $dim)" "$(fg $cyn)" "${stage^^}" "$R"
    echo

    # ---- HUD --------------------------------------------------------------
    local rail; rail="$(fg $mag)▌$R"
    printf '   %s %sHP  %s  ' "$rail" "$(fg $wht)" "$R"
    motd_bar "$hp" 24 '█' '░' "$(_motd_level_colour "$hp")" "$dim"
    printf '  %s%3d%%%s  %smemory free%s\n' "$(fg $wht)" "$hp" "$R" "$(fg $dim)" "$R"

    printf '   %s %sMP  %s  ' "$rail" "$(fg $wht)" "$R"
    motd_bar "$mp" 24 '█' '░' "$(_motd_level_colour "$mp")" "$dim"
    printf '  %s%3d%%%s  %sdisk free%s\n' "$(fg $wht)" "$mp" "$R" "$(fg $dim)" "$R"

    if [ -n "$temp" ]; then
        # 30°C = empty bar, 95°C = full
        heat_pct=$(( (temp - 30) * 100 / 65 ))
        heat_c=$(_motd_level_colour $(( 100 - heat_pct )))
        printf '   %s %sHEAT%s  ' "$rail" "$(fg $wht)" "$R"
        motd_bar "$heat_pct" 24 '█' '░' "$heat_c" "$dim"
        printf '  %s%3d°C%s\n' "$(fg $wht)" "$temp" "$R"
    fi

    printf '   %s %sTIME%s  %s%s%s  %splayed%s' \
        "$rail" "$(fg $wht)" "$R" "$(fg $cyn)" "$(motd_uptime_clock "$secs")" "$R" "$(fg $dim)" "$R"
    if [ "$pads" -gt 0 ]; then
        printf '       %sPADS%s  %s%s connected%s\n' "$(fg $wht)" "$R" "$(fg $grn)" "$pads" "$R"
    else
        printf '       %sPADS%s  %sinsert controller%s\n' "$(fg $wht)" "$R" "$(fg $yel)" "$R"
    fi

    if [ "${roms:-0}" -gt 0 ]; then
        printf '   %s %sLOOT%s  %s%s%s roms %s·%s %s%s%s systems\n' \
            "$rail" "$(fg $wht)" "$R" "$(fg $yel)" "$roms" "$R" "$(fg $dim)" "$R" "$(fg $yel)" "$systems" "$R"
    fi
    echo

    # ---- footer -----------------------------------------------------------
    if [ "$MOTD_LIVE" = 1 ]; then
        printf '   %s! LIVE MODE — progress will not be saved%s\n' "$(fg $red)" "$R"
    fi
    local tip
    tip=$(motd_pick_daily \
        "Select+Start quits a game back to the menu." \
        "Select+R saves state, Select+L loads it." \
        "Select+X opens the RetroArch menu mid-game." \
        "Select+Left/Right picks the save-state slot." \
        "Press a button as a game launches for the runcommand menu.")
    printf '   %sTIP %s%s%s\n' "$(fg $cyn)" "$(fg $dim)" "$tip" "$R"
    printf '   %s%s▶ PRESS START%s %s· emulationstation%s\n' "$(blink)" "$(fg $yel)" "$R" "$(fg $dim)" "$R"
    echo
}
