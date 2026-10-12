#!/usr/bin/env bash

set -uo pipefail


LOCAL_DIR="${LOCAL_DIR:-$HOME/Documents/all/for_l/Wall}"
URLS_FILE="${URLS_FILE:-$HOME/Documents/all/for_l/urls.txt}"
GOINFRE="${GOINFRE:-$HOME/goinfre}"

ME="$(id -un)"                              
RUNDIR="${XDG_RUNTIME_DIR:-/dev/shm}"       
SLOT_A="$RUNDIR/wp-current-a-$ME.jpg"
SLOT_B="$RUNDIR/wp-current-b-$ME.jpg"

LOCK_FILE="$GOINFRE/wallpaper-rotate-$ME.lock"
LOG_FILE="$GOINFRE/wp.log"

SLEEP_SECS="${SLEEP_SECS:-60}"
REMOTE_PROB="${REMOTE_PROB:-50}"



mkdir -p "$GOINFRE" "$RUNDIR" 2>/dev/null || true



exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another instance is already running" >&2
    exit 1
fi



[ -t 1 ] || exec >>"$LOG_FILE" 2>&1



SLEEP_PID=""
trap 'kill "${SLEEP_PID:-}" 2>/dev/null; rm -f "$SLOT_A.tmp" "$SLOT_B.tmp"; exit 0' INT TERM HUP



nap() {
    sleep "$SLEEP_SECS" 9>&- & SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
}



if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    bus="/run/user/$(id -u)/bus"
    [ -S "$bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
fi



set_wallpaper() {
    local p="${1// /%20}"
    if ! gsettings set org.gnome.desktop.background picture-uri      "file://$p" \
      || ! gsettings set org.gnome.desktop.background picture-uri-dark "file://$p"; then
        echo "[!] gsettings failed for: $1"
        return 1
    fi
}



list_local() {
    find "$LOCAL_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \)
}

mapfile -t LOCAL_WALLS < <(list_local)
LOCAL_N=${#LOCAL_WALLS[@]}
echo "[*] local wallpapers: $LOCAL_N"

REMOTE_N=$(grep -c '^https\?://' "$URLS_FILE" 2>/dev/null || true)
REMOTE_N=${REMOTE_N:-0}
echo "[*] remote URLs: $REMOTE_N"
[ "$REMOTE_N" -eq 0 ] && echo "[!] $URLS_FILE missing, empty or has no valid URLs — remote disabled."



LAST_LOCAL=""
LAST_REMOTE=""
PICK=""

pick_local() {
    mapfile -t LOCAL_WALLS < <(list_local)
    LOCAL_N=${#LOCAL_WALLS[@]}
    [ "$LOCAL_N" -eq 0 ] && return 1
    local choice tries=0
    while :; do
        choice="${LOCAL_WALLS[$((RANDOM % LOCAL_N))]}"
        { [ "$choice" != "$LAST_LOCAL" ] || [ "$LOCAL_N" -eq 1 ] || [ $((++tries)) -ge 10 ]; } && break
    done
    LAST_LOCAL="$choice"
    PICK="$choice"
}

pick_remote() {
    [ "$REMOTE_N" -gt 0 ] || return 1
    local choice tries=0
    while :; do
        choice=$(grep '^https\?://' "$URLS_FILE" | tr -d '\r' | shuf -n 1)
        { [ "$choice" != "$LAST_REMOTE" ] || [ "$REMOTE_N" -le 1 ] || [ $((++tries)) -ge 10 ]; } && break
    done
    LAST_REMOTE="$choice"
    PICK="$choice"
}


TOGGLE=0
while :; do
    if [ "$REMOTE_N" -gt 0 ] && [ $((RANDOM % 100)) -lt "$REMOTE_PROB" ]; then
        if pick_remote; then
            url=$PICK
            if [ "$TOGGLE" -eq 0 ]; then slot=$SLOT_A; else slot=$SLOT_B; fi
            if curl -fsSL --connect-timeout 5 --max-time 40 \
                    --retry 2 --retry-connrefused --retry-delay 2 \
                    -o "$slot.tmp" "$url" \
               && mv "$slot.tmp" "$slot"; then
                TOGGLE=$((1 - TOGGLE))
                set_wallpaper "$slot" \
                    && echo "[$(date +%H:%M:%S)] remote: $(basename "$url")" \
                    || echo "[$(date +%H:%M:%S)] remote (set failed): $(basename "$url")"
                nap
                continue
            else
                echo "[!] remote fetch failed, falling back to local: $url"
                rm -f "$slot.tmp"
            fi
        fi
    fi

    if pick_local; then
        path=$PICK
        set_wallpaper "$path" \
            && echo "[$(date +%H:%M:%S)] local : $(basename "$path")" \
            || echo "[$(date +%H:%M:%S)] local (set failed): $(basename "$path")"
    else
        echo "[!] nothing to set"
    fi

    nap
done