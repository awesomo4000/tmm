#!/bin/bash
# tmux-pin - keep a pane pinned to a display.
#
# A tmux pane belongs to exactly one window, so a pane cannot simply "stay
# visible". Instead, each display (tmux client) owns one pinned pane, marked
# with @pin_display=<that display's tty>. Whenever a display changes what it
# is looking at, its own pane is reparented into that window with join-pane,
# which preserves the pty and the running process. Other displays are
# untouched.
#
#   tmux-pin.sh --tty=/dev/ttysNNN   place that display's pin (spawn if absent)
#   tmux-pin.sh --reap               kill pins whose display is gone
#
# Environment:
#   PIN_CMD     command to spawn when a display has no pin yet (required to
#               bootstrap; without it this script only moves existing pins)
#   PIN_SIZE    columns for the pinned pane (default 30)
#   PIN_SOCKET  tmux socket name, for testing against a throwaway server
#
# Hooks - note the --flag=value form. An empty tmux format expands to NOTHING,
# which would delete the argument and silently shift the ones after it:
#   PIN="run-shell '/path/to/tmux-pin.sh --tty=#{q:client_tty}'"
#   set-hook -ga session-window-changed "$PIN"
#   set-hook -ga client-session-changed "$PIN"
#   set-hook -ga client-attached        "$PIN"
#   set-hook -ga client-detached "run-shell '/path/to/tmux-pin.sh --reap'"
#
# Deliberately NO #{hook_client} fallback. On externally driven window changes
# hook_client is an arbitrary client, and acting on it drags one display's pin
# into a session that display is not even viewing.
set -u

T=(tmux); [ -n "${PIN_SOCKET:-}" ] && T=(tmux -L "$PIN_SOCKET")
SIZE=${PIN_SIZE:-30}
CMD=${PIN_CMD:-}

tty=""; reap=0
for a in "$@"; do
  case "$a" in
    --tty=*) tty=${a#--tty=} ;;
    --reap)  reap=1 ;;
  esac
done

# Kill pins whose display is gone.
if [ "$reap" = 1 ]; then
  live=$("${T[@]}" list-clients -F '#{client_tty}' 2>/dev/null)
  "${T[@]}" list-panes -a -F '#{pane_id} #{@pin_display}' 2>/dev/null \
  | while read -r pane owner; do
      [ -z "${owner:-}" ] && continue
      grep -qxF "$owner" <<<"$live" || "${T[@]}" kill-pane -t "$pane" 2>/dev/null
    done
  exit 0
fi

case "$tty" in /dev/*) ;; *) exit 0 ;; esac

# Resolve the display's window via the authoritative client table.
# display-message -c is NOT reliable here: during a client-attached race it can
# report another client's window entirely (measured: -c on a client attached to
# "beta" returned alpha:1). Map tty -> session from list-clients, then ask that
# session for its current window.
sess=$("${T[@]}" list-clients -F '#{client_tty} #{session_id}' 2>/dev/null \
       | awk -v t="$tty" '$1==t{print $2; exit}')
[ -z "$sess" ] && exit 0
tgt_win=$("${T[@]}" display-message -p -t "$sess" -F '#{window_id}' 2>/dev/null)
[ -z "$tgt_win" ] && exit 0

pane=$("${T[@]}" list-panes -a -F '#{pane_id} #{@pin_display}' 2>/dev/null \
       | awk -v t="$tty" '$2==t{print $1; exit}')

# join-pane reshapes windows and can re-trigger the hook that called us.
guard="@pin_moving_$(echo "$tty" | tr -c 'A-Za-z0-9' '_')"
[ "$("${T[@]}" show-options -gqv "$guard")" = "1" ] && exit 0
"${T[@]}" set-option -g "$guard" 1

if [ -z "$pane" ]; then
  if [ -n "$CMD" ]; then
    new=$("${T[@]}" split-window -b -h -l "$SIZE" -d -t "$tgt_win" \
                    -P -F '#{pane_id}' "$CMD" 2>/dev/null)
    [ -n "$new" ] && "${T[@]}" set-option -p -t "$new" @pin_display "$tty"
  fi
else
  cur_win=$("${T[@]}" display-message -p -t "$pane" -F '#{window_id}' 2>/dev/null)
  [ "$cur_win" != "$tgt_win" ] && \
    "${T[@]}" join-pane -b -h -l "$SIZE" -d -s "$pane" -t "$tgt_win" 2>/dev/null
fi

"${T[@]}" set-option -gu "$guard"
