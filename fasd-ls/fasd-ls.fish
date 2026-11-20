function ls --wraps ls --description 'ls that keeps the system folders out of /'
    set -l at 0
    test "$PWD" = /; and set at 1
    for a in $argv
        test "$a" = /; and set at 1
    end
    if test $at = 1
        command ls --color=auto --ignore=bin --ignore=boot --ignore=dev --ignore=etc --ignore=home --ignore=lib --ignore=lib64 --ignore=mnt --ignore=opt --ignore=proc --ignore=root --ignore=run --ignore=sbin --ignore=srv --ignore=sys --ignore=tmp --ignore=usr --ignore=var --ignore=lost+found --ignore=swapfile --ignore=.hidden --ignore=.snapshots --ignore=efi $argv
    else
        command ls --color=auto $argv
    end
end
function cd --description 'cd that refuses system folders'
    if status is-interactive; and test (count $argv) -ge 1
        set -l t $argv[-1]
        string match -q -- '-*' $t; and set t ''
        if test -n "$t"
            string match -q -- '/*' $t; or set t $PWD/$t
            set t (path normalize $t)
            if string match -rq -- '^/(bin|sbin|lib|lib64|sys|proc|dev|boot|root|srv|mnt|opt|home|run|etc|usr|var)(/|$)' $t
                echo "cd: $argv[-1]: No such file or directory" >&2
                return 1
            end
        end
    end
    builtin cd $argv
end
