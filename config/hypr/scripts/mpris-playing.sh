#!/usr/bin/env bash
# Keeps a list of PIDs that are playing media (MPRIS "Playing" or an uncorked audio stream),
# read by config/autopip.lua, which is notified through hyprctl whenever the list changes.
set -u

out="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr-pip-playing"

exec 9>"$out.lock"
flock -n 9 || exit 0

# Only rewrite and notify when the combined list actually changes
merge() {
    {
        flock 8
        local new
        new=$(cat "$out.mpris" "$out.audio" 2>/dev/null | sort -un)
        [[ -f $out && $new == "$(<"$out")" ]] && return
        printf '%s\n' "$new" >"$out.tmp" && mv -f "$out.tmp" "$out"
        hyprctl eval 'local m = package.loaded["config.autopip"]; if m and m.playing_changed then m.playing_changed() end' \
            >/dev/null 2>&1
    } 8>"$out.merge.lock"
}

mpris_scan() {
    local name status pid
    while read -r name _; do
        [[ $name == org.mpris.MediaPlayer2.* ]] || continue
        status=$(busctl --user get-property "$name" /org/mpris/MediaPlayer2 \
            org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null) || continue
        [[ $status == 's "Playing"' ]] || continue
        pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetConnectionUnixProcessID s "$name" 2>/dev/null) || continue
        echo "${pid#u }"
    done < <(busctl --user list --acquired --no-legend --no-pager 2>/dev/null) >"$out.mpris.tmp"
    mv -f "$out.mpris.tmp" "$out.mpris"
}

# Chromium/Electron play audio from a helper process; also report its ancestors running the same binary
with_parents() {
    local pid=$1 exe k v ppid
    exe=$(readlink "/proc/$pid/exe") || return
    while ((pid > 1)); do
        echo "$pid"
        ppid=
        while read -r k v; do [[ $k == PPid: ]] && ppid=$v && break; done <"/proc/$pid/status"
        [[ -n $ppid && $(readlink "/proc/$ppid/exe" 2>/dev/null) == "$exe" ]] || break
        pid=$ppid
    done
}

audio_scan() {
    local pid
    for pid in $(jq -rn \
        --argjson s "$(pactl -f json list sink-inputs 2>/dev/null || echo '[]')" \
        --argjson c "$(pactl -f json list clients 2>/dev/null || echo '[]')" \
        '($c | map({ key: (.index | tostring), value: (.properties["application.process.id"] // .properties["pipewire.sec.pid"]) })
          | from_entries) as $pids
         | $s[] | select(.corked == false) | $pids[.client | tostring] // empty' 2>/dev/null); do
        with_parents "$pid"
    done >"$out.audio.tmp"
    mv -f "$out.audio.tmp" "$out.audio"
}

# Players without MPRIS (Nuvio, plain mpv) still cork their audio stream when paused
audio_watch() {
    while true; do
        audio_scan
        merge
        pactl subscribe 2>/dev/null | while read -r line; do
            [[ $line == *sink-input* ]] || continue
            # Coalesce bursts of events into one scan
            while read -r -t 0.2 _; do :; done
            audio_scan
            merge
        done
        sleep 2
    done
}

mpris_watch() {
    while true; do
        mpris_scan
        merge
        busctl --user monitor --json=short \
            --match "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2',arg0='org.mpris.MediaPlayer2.Player'" \
            --match "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'" \
            2>/dev/null | while read -r _; do
            while read -r -t 0.2 _; do :; done
            mpris_scan
            merge
        done
        sleep 2
    done
}

rm -f "$out.audio"
# Watchers run in the background so the trap fires immediately (bash defers it during foreground jobs)
trap 'trap - TERM; kill 0' TERM INT HUP
if command -v pactl >/dev/null && command -v jq >/dev/null; then
    audio_watch &
fi
mpris_watch &
wait
