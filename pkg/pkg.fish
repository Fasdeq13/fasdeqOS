complete -c pkg -f
complete -c pkg -n '__fish_use_subcommand' -a 'install remove update upgrade sysupgrade search list info rebuild'
complete -c pkg -n '__fish_seen_subcommand_from install info' -a '(/System/pkg-backend -Slq)'
complete -c pkg -n '__fish_seen_subcommand_from remove' -a '(/System/pkg-backend -Qeq)'
