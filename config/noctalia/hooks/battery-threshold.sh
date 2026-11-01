#!/usr/bin/env bash
# Run by Noctalia's battery_percentage_changed hook; warns once per threshold crossing.
set -euo pipefail

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia"
state_file="$state_dir/battery-percent"
percent="${NOCTALIA_BATTERY_PERCENT:-}"
battery_state="${NOCTALIA_BATTERY_STATE:-unknown}"

[[ "$percent" =~ ^[0-9]+$ ]] || exit 0
mkdir -p "$state_dir"

previous=""
[[ -r "$state_file" ]] && previous="$(<"$state_file")"
printf '%s\n' "$percent" > "$state_file"

[[ "$battery_state" == "discharging" ]] || exit 0
[[ "$previous" =~ ^[0-9]+$ ]] || exit 0

if (( previous >= 10 && percent < 10 )); then
    notify-send -u critical -i battery-caution "Battery critical" "Battery is at ${percent}%. Plug in now."
elif (( previous >= 20 && percent < 20 )); then
    notify-send -u normal -i battery-low "Battery low" "Battery is at ${percent}%."
fi
