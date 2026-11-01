# Environment (also applies to non-interactive shells)
fish_add_path -g ~/.local/bin ~/.cargo/bin ~/go/bin
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx MANROFFOPT -c
set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"

if status is-interactive
    # Prompt, direnv, zoxide, fzf (init scripts cached in ~/.cache/fish)
    __cached_source starship init fish --print-full-init
    __cached_source direnv hook fish
    __cached_source zoxide init fish --cmd cd

    set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git'
    set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
    set -gx FZF_CTRL_T_OPTS "--preview 'bat --color=always --style=numbers --line-range=:300 {}'"
    set -gx FZF_ALT_C_COMMAND 'fd --type d --hidden --follow --exclude .git'
    set -gx FZF_ALT_C_OPTS "--preview 'eza --tree --level=2 --icons=always --color=always {}'"
    __cached_source fzf --fish

    # Collapse previous prompts to just the prompt character
    function starship_transient_prompt_func
        starship module character $argv
    end
    functions -q enable_transience && enable_transience

    # Notify when commands longer than 10s finish (from cachyos-fish-config)
    test -f /usr/share/cachyos-fish-config/conf.d/done.fish
    and source /usr/share/cachyos-fish-config/conf.d/done.fish

    # Better ls
    type -q eza && alias ls='eza --icons=auto --group-directories-first -1'

    # Abbrs
    abbr lg 'lazygit'
    abbr gd 'git diff'
    abbr ga 'git add'
    abbr gaa 'git add .'
    abbr gc 'git commit'
    abbr gcam 'git commit -am'
    abbr gl 'git log --oneline --graph --decorate'
    abbr gs 'git status'
    abbr gst 'git stash'
    abbr gsp 'git stash pop'
    abbr gp 'git push'
    abbr gpl 'git pull'
    abbr gsw 'git switch'
    abbr gsm --function __abbr_git_switch_default
    abbr gb 'git branch'
    abbr gbd 'git branch -d'
    abbr gco 'git checkout'
    abbr gsh 'git show'

    abbr l 'ls'
    abbr ll 'ls -l'
    abbr la 'ls -a'
    abbr lla 'ls -la'
end
