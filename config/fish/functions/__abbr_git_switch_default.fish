function __abbr_git_switch_default --description 'Expand to git switch <default branch>'
    set -l ref (git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    if test -n "$ref"
        echo git switch (string replace -r '^origin/' '' -- $ref)
    else if git show-ref --verify --quiet refs/heads/master 2>/dev/null
        echo git switch master
    else
        echo git switch main
    end
end
