#!/bin/bash
# Example pinned payload. Shows which display owns it and which window it is
# currently living in, so you can watch it move. Inside a pane, plain `tmux`
# already targets the right server via $TMUX, so no socket plumbing is needed.
set -u
while :; do
  owner=$(tmux show-options -pqv -t "$TMUX_PANE" @pin_display 2>/dev/null)
  where=$(tmux display-message -p -t "$TMUX_PANE" -F '#{session_name}:#{window_index}' 2>/dev/null)
  clear
  printf '\033[38;5;213m pin\033[0m\n\n display:\n  %s\n\n window:\n  %s\n' "${owner:-?}" "${where:-?}"
  sleep 1
done
