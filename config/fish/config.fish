set -g fish_greeting
if status is-interactive
    starship init fish | source
end
