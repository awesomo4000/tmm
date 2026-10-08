#!/bin/bash
# tmux-pin-install - inspect a live tmux server and install/remove the hooks.
#
#   tmux-pin-install.sh --check      report state, change nothing
#   tmux-pin-install.sh --print      print a config fragment, change nothing
#   tmux-pin-install.sh --install    append hooks to the RUNNING server (no file edits)
#   tmux-pin-install.sh --uninstall  remove only tmux-pin's hook entries
#
# tmux hooks are arrays, so this appends with -ga and never clobbers hooks the
# user already has, and removes single entries by index on uninstall.
set -u
T=(tmux); [ -n "${PIN_SOCKET:-}" ] && T=(tmux -L "$PIN_SOCKET")
DIR=${PIN_DIR:-$(cd "$(dirname "$0")" && pwd)}
PIN="$DIR/tmux-pin.sh"
MARK="tmux-pin.sh"
HOOKS="session-window-changed client-session-changed client-attached"

cmd_pin="run-shell '$PIN --tty=#{q:client_tty}'"
cmd_reap="run-shell '$PIN --reap'"

hook_has_pin() { "${T[@]}" show-hooks -g 2>/dev/null | grep -q "^$1\[[0-9]*\] .*$MARK"; }

report() {
  echo "tmux:             $("${T[@]}" -V 2>/dev/null)"
  echo "mouse:            $("${T[@]}" show -gv mouse 2>/dev/null)  (a clickable pin needs 'on')"
  echo "prefix:           $("${T[@]}" show -gv prefix 2>/dev/null)"
  echo "default-terminal: $("${T[@]}" show -gv default-terminal 2>/dev/null)"
  echo
  echo "hooks tmux-pin wants, and what is already there:"
  for h in $HOOKS client-detached; do
    n=$("${T[@]}" show-hooks -g 2>/dev/null | grep -c "^$h\[")
    mine=$(hook_has_pin "$h" && echo " [tmux-pin present]" || echo "")
    printf '  %-24s %s existing entr%s%s\n' "$h" "$n" "$([ "$n" = 1 ] && echo y || echo ies)" "$mine"
    "${T[@]}" show-hooks -g 2>/dev/null | grep "^$h\[" | sed 's/^/      /'
  done
  echo
  echo "pins currently placed:"
  "${T[@]}" list-panes -a -F '  #{session_name}:#{window_index} #{pane_id} display=#{@pin_display}' 2>/dev/null \
    | grep -v 'display=$' || echo "  (none)"
}

case "${1:---check}" in
  --check) report ;;
  --print)
    # Guarded with %if so re-sourcing (prefix r) cannot stack duplicates:
    # set-hook -ga appends every time, so an unguarded include grows without bound.
    echo "# tmux-pin: keep a pane pinned to a display."
    echo "# Save as ~/.config/tmux-pin/pin.tmux.conf and add one line to ~/.tmux.conf:"
    echo "#     source-file -q ~/.config/tmux-pin/pin.tmux.conf"
    echo "%if \"#{!=:#{@pin_hooks_loaded},1}\""
    echo "set -g @pin_hooks_loaded 1"
    for h in $HOOKS; do echo "set-hook -ga $h \"$cmd_pin\""; done
    echo "set-hook -ga client-detached \"$cmd_reap\""
    echo "%endif"
    ;;
  --install)
    for h in $HOOKS; do
      if hook_has_pin "$h"; then echo "already installed: $h"
      else "${T[@]}" set-hook -ga "$h" "$cmd_pin" && echo "appended: $h"; fi
    done
    if hook_has_pin client-detached; then echo "already installed: client-detached"
    else "${T[@]}" set-hook -ga client-detached "$cmd_reap" && echo "appended: client-detached"; fi
    ;;
  --uninstall)
    for h in $HOOKS client-detached; do
      # Remove highest index first: removing one shifts the rest down.
      idxs=$("${T[@]}" show-hooks -g 2>/dev/null | grep "^$h\[.*$MARK" \
             | sed -E "s/^$h\[([0-9]+)\].*/\1/" | sort -rn)
      for i in $idxs; do "${T[@]}" set-hook -gu "$h[$i]" && echo "removed: $h[$i]"; done
    done
    ;;
  *) echo "usage: $0 [--check|--print|--install|--uninstall]" >&2; exit 2 ;;
esac
