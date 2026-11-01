# Overrides pure's vendor fish_title, which depends on pure_* variables
function fish_title --argument-names last_command
    set -l folder (prompt_pwd --dir-length=0)
    set -l current (status current-command)
    if test -n "$last_command"
        echo "$folder: $last_command - $current"
    else
        echo "$folder - $current"
    end
end
