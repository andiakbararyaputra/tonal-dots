function __cached_source --description 'Source the output of an init command, cached until the binary or config.fish changes'
    set -l bin (command -s $argv[1]); or return
    set -l cache_dir (set -q XDG_CACHE_HOME; and echo $XDG_CACHE_HOME; or echo ~/.cache)/fish
    set -l cache $cache_dir/init-$argv[1].fish

    if not test -s $cache; or test $bin -nt $cache; or test $__fish_config_dir/config.fish -nt $cache
        mkdir -p $cache_dir
        if not $argv >$cache
            rm -f $cache
            return 1
        end
    end
    source $cache
end
