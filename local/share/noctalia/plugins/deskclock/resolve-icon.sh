#!/usr/bin/env bash
# Prints an icon file path for an app name / desktop id / icon name, or nothing.
set -uo pipefail

name="${1:-}"
[[ -n "$name" ]] || exit 0
[[ "$name" == /* && -f "$name" ]] && { printf '%s\n' "$name"; exit 0; }

lower="${name,,}"
icon="$lower"
appdirs=("$HOME/.local/share/applications" /usr/share/applications /var/lib/flatpak/exports/share/applications "$HOME/.local/share/flatpak/exports/share/applications")

desktop=""
for d in "${appdirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d/$name.desktop" "$d/$lower.desktop"; do
        [[ -f "$f" ]] && { desktop="$f"; break 2; }
    done
done
if [[ -z "$desktop" ]]; then
    desktop=$(grep -rilE "^(StartupWMClass|Name)=$name\$" "${appdirs[@]}" 2>/dev/null | head -n1)
fi
if [[ -n "$desktop" ]]; then
    found=$(grep -m1 '^Icon=' "$desktop" | cut -d= -f2-)
    [[ -n "$found" ]] && icon="$found"
fi

[[ "$icon" == /* && -f "$icon" ]] && { printf '%s\n' "$icon"; exit 0; }

for theme in Papirus-Dark Papirus hicolor breeze Adwaita; do
    for base in "$HOME/.local/share/icons" /usr/share/icons; do
        dir="$base/$theme"
        [[ -d "$dir" ]] || continue
        for size in 48x48 64x64 scalable 32x32 128x128 256x256; do
            for f in "$dir/$size/apps/$icon.svg" "$dir/$size/apps/$icon.png"; do
                [[ -f "$f" ]] && { printf '%s\n' "$f"; exit 0; }
            done
        done
    done
done

for f in "/usr/share/pixmaps/$icon.svg" "/usr/share/pixmaps/$icon.png"; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; exit 0; }
done
