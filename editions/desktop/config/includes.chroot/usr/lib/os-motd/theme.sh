# shellcheck shell=bash
# =============================================================================
# /usr/lib/os-motd/theme.sh (layer: editions/desktop)
#
# Desktop greeting: warm, quiet, low contrast. A cup of tea, a few facts said
# plainly, one small note that changes daily.
# =============================================================================

motd_theme() {
    # warm palette — all mid/low saturation so nothing shouts
    local steam=245 cup=180 peach=216 cream=223 sage=108 rose=174 dim=244

    local hour greet up
    hour=$(date +%-H)
    if   [ "$hour" -lt 5 ];  then greet="Still up${MOTD_USER:+, $MOTD_USER}?"
    elif [ "$hour" -lt 12 ]; then greet="Good morning${MOTD_USER:+, $MOTD_USER}."
    elif [ "$hour" -lt 17 ]; then greet="Good afternoon${MOTD_USER:+, $MOTD_USER}."
    elif [ "$hour" -lt 22 ]; then greet="Good evening${MOTD_USER:+, $MOTD_USER}."
    else                          greet="Winding down${MOTD_USER:+, $MOTD_USER}?"
    fi

    up=$(motd_uptime_short "$(motd_uptime_s)")
    motd_mem; motd_disk /

    local mem_used=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
    local release="$OS_NAME $OS_VER${OS_CODE:+ · $OS_CODE}"
    local today
    today=$(date '+%A, %-d %B')

    local note
    note=$(motd_pick_daily \
        "Ctrl+R searches your shell history — no retyping." \
        "cd - takes you back to wherever you just were." \
        "Ctrl+L clears the screen without losing what you typed." \
        "free -h and df -h: two quick looks at how the machine is doing." \
        "!! repeats the last command. sudo !! when you forgot sudo." \
        "Close a tab or two. Nothing in there is going anywhere." \
        "Step away for five minutes. It'll still be here." \
        "Ctrl+A / Ctrl+E jump to the start / end of the line.")

    #           art (16 cols)        text
    local -a art=(
        "     (  )  (    "
        "      )  (  )   "
        "    .--------.  "
        "    |        |_ "
        "    |        | |"
        "    |        |_|"
        "     \\______/   "
    )
    local -a artc=("$steam" "$steam" "$cup" "$cup" "$cup" "$cup" "$cup")

    local -a txt txtc
    txt[0]="";                   txtc[0]=$cream
    txt[1]="$greet";             txtc[1]=$peach
    txt[2]="$today";             txtc[2]=$dim
    txt[3]="";                   txtc[3]=$cream
    txt[4]="$release";           txtc[4]=$cream
    txt[5]="up $up · load $(motd_load1)"; txtc[5]=$sage
    txt[6]="$(motd_human_kb "$mem_used") of $(motd_human_kb "$MEM_TOTAL_KB") memory in use · $(motd_human_kb "$DISK_AVAIL_KB") free on /"
    txtc[6]=$sage

    echo
    local i
    for i in "${!art[@]}"; do
        printf '  %s%s%s   ' "$(fg "${artc[$i]}")" "${art[$i]}" "$(rst)"
        if [ "$i" = 1 ]; then
            printf '%s%s%s%s\n' "$(bold)" "$(fg "${txtc[$i]}")" "${txt[$i]}" "$(rst)"
        else
            printf '%s%s%s\n' "$(fg "${txtc[$i]}")" "${txt[$i]}" "$(rst)"
        fi
    done
    echo
    if [ "$MOTD_LIVE" = 1 ]; then
        printf '  %s· live session — nothing here is kept after reboot%s\n' "$(fg "$rose")" "$(rst)"
    fi
    printf '  %s· %s%s\n' "$(fg "$dim")" "$note" "$(rst)"
    echo
}
