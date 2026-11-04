#!/usr/bin/env bash
# Symlink tonal-dots configs into place, backing up anything already there.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BACKUP="$CONFIG_HOME/tonal-dots-backup-$(date +%Y%m%d-%H%M%S)"

# name|source (relative to repo)|target
LINKS=(
    "hypr|config/hypr|$CONFIG_HOME/hypr"
    "noctalia|config/noctalia|$CONFIG_HOME/noctalia"
    "deskclock|local/share/noctalia/plugins/deskclock|$DATA_HOME/noctalia/plugins/deskclock"
    "kitty|config/kitty|$CONFIG_HOME/kitty"
    "foot|config/foot|$CONFIG_HOME/foot"
    "alacritty|config/alacritty|$CONFIG_HOME/alacritty"
    "fish|config/fish|$CONFIG_HOME/fish"
    "starship|config/starship.toml|$CONFIG_HOME/starship.toml"
    "btop|config/btop|$CONFIG_HOME/btop"
    "nvim|config/nvim|$CONFIG_HOME/nvim"
    "fastfetch|config/fastfetch|$CONFIG_HOME/fastfetch"
    "uwsm|config/uwsm|$CONFIG_HOME/uwsm"
    "kvantum|config/Kvantum|$CONFIG_HOME/Kvantum"
    "dolphin|local/share/kxmlgui5/dolphin|$DATA_HOME/kxmlgui5/dolphin"
)

DRY_RUN=0
ONLY=()

usage() {
    cat <<EOF
Usage: ./install.sh [--dry-run] [--only NAME...]

Symlinks the configs in this repo into your home directory.
Existing files are moved to $CONFIG_HOME/tonal-dots-backup-<timestamp>/.

Options:
  -n, --dry-run     Show what would happen without changing anything
  -o, --only NAME   Install only the given components (repeatable)
  -l, --list        List available components
  -h, --help        Show this help

Components: $(for l in "${LINKS[@]}"; do printf '%s ' "${l%%|*}"; done)
EOF
}

while (($#)); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -o|--only)
            shift
            while (($#)) && [[ $1 != -* ]]; do ONLY+=("$1"); shift; done
            continue
            ;;
        -l|--list) for l in "${LINKS[@]}"; do echo "${l%%|*}"; done; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

for name in "${ONLY[@]}"; do
    found=0
    for l in "${LINKS[@]}"; do [[ ${l%%|*} == "$name" ]] && found=1; done
    ((found)) || { echo "Unknown component: $name (see --list)" >&2; exit 1; }
done

run() {
    if ((DRY_RUN)); then echo "  [dry-run] $*"; else "$@"; fi
}

selected() {
    ((${#ONLY[@]} == 0)) && return 0
    local n
    for n in "${ONLY[@]}"; do [[ $n == "$1" ]] && return 0; done
    return 1
}

linked=0 skipped=0 backed_up=0

for entry in "${LINKS[@]}"; do
    IFS='|' read -r name src target <<<"$entry"
    selected "$name" || continue
    src="$REPO/$src"

    if [[ -L $target && "$(readlink -f "$target")" == "$(readlink -f "$src")" ]]; then
        echo "= $name: already linked"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ -e $target || -L $target ]]; then
        echo "~ $name: backing up $target"
        run mkdir -p "$BACKUP"
        run mv "$target" "$BACKUP/$name"
        backed_up=$((backed_up + 1))
    fi

    echo "+ $name: $target -> $src"
    run mkdir -p "$(dirname "$target")"
    run ln -s "$src" "$target"
    linked=$((linked + 1))
done

echo
echo "Linked: $linked  Already linked: $skipped  Backed up: $backed_up"
if ((backed_up)) && ! ((DRY_RUN)); then
    echo "Backups saved in: $BACKUP"
fi
if ((linked)) && ! ((DRY_RUN)); then
    echo "Reload Hyprland (hyprctl reload) and restart Noctalia to apply."
fi
