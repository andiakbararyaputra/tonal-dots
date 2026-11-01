#!/usr/bin/env bash
# Keeps a list of PIDs whose MPRIS player is "Playing", read by config/autopip.lua.
set -u

out="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr-pip-playing"

exec 9>"$out.lock"
flock -n 9 || exit 0

scan() {
    local tmp="$out.tmp" name status pid
    : >"$tmp"
    while read -r name _; do
        [[ $name == org.mpris.MediaPlayer2.* ]] || continue
        status=$(busctl --user get-property "$name" /org/mpris/MediaPlayer2 \
            org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null) || continue
        [[ $status == 's "Playing"' ]] || continue
        pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetConnectionUnixProcessID s "$name" 2>/dev/null) || continue
        echo "${pid#u }" >>"$tmp"
    done < <(busctl --user list --acquired --no-legend --no-pager 2>/dev/null)
    mv -f "$tmp" "$out"
}

while true; do
    scan
    busctl --user monitor --json=short \
        --match "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2'" \
        --match "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'" \
        2>/dev/null | while read -r _; do
        # Coalesce bursts of signals into one scan
        while read -r -t 0.2 _; do :; done
        scan
    done
    sleep 2
done
