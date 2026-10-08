#!/bin/bash
# Demo: per-display pinned panes, on a THROWAWAY tmux server.
# Your real server (socket "default") is never touched.
#   ./demo.sh          headless: print where each pin lands
#   ./demo.sh --watch  set it up, then tell you how to attach and play
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
S=tmuxpindemo
export PIN_SOCKET=$S

tmux -L $S kill-server 2>/dev/null || true
for s in alpha beta; do
  tmux -L $S new-session  -d -s $s -x 170 -y 45 "bash -c 'echo $s window 1; sleep 3000'"
  tmux -L $S new-window   -d -t $s "bash -c 'echo $s window 2; sleep 3000'"
  tmux -L $S new-window   -d -t $s "bash -c 'echo $s window 3; sleep 3000'"
done

PIN="run-shell 'PIN_SOCKET=$S PIN_CMD=$HERE/example-payload.sh $HERE/tmux-pin.sh --tty=#{q:client_tty}'"
tmux -L $S set-hook -ga session-window-changed "$PIN"
tmux -L $S set-hook -ga client-session-changed "$PIN"
tmux -L $S set-hook -ga client-attached        "$PIN"
tmux -L $S set-hook -ga client-detached "run-shell 'PIN_SOCKET=$S $HERE/tmux-pin.sh --reap'"

if [ "${1:-}" = "--watch" ]; then
  cat <<EOF

Throwaway server "$S" is ready, with sessions alpha and beta (3 windows each).

Open TWO terminal windows and run one of these in each:

    tmux -L $S attach -t alpha
    tmux -L $S attach -t beta

Then switch windows in either one (prefix is Ctrl-b here unless your config
changes it):

    Ctrl-b 1 / 2 / 3

The pink pin follows the display that switched, and leaves the other alone.

Tear down with:   tmux -L $S kill-server
EOF
  exit 0
fi

# Headless: two ptys standing in for two displays.
script -q /dev/null tmux -L $S attach -t alpha >/dev/null 2>&1 &
script -q /dev/null tmux -L $S attach -t beta  >/dev/null 2>&1 &
sleep 1.5
A=$(tmux -L $S list-clients -F '#{client_tty} #{client_session}' | awk '$2=="alpha"{print $1}')
B=$(tmux -L $S list-clients -F '#{client_tty} #{client_session}' | awk '$2=="beta"{print $1}')
printf 'display A = %s (alpha)\ndisplay B = %s (beta)\n\n' "$A" "$B"
tmux -L $S switch-client -c "$A" -t alpha:1; sleep 0.5
tmux -L $S switch-client -c "$B" -t beta:1;  sleep 0.5

report() {
  for pair in "A $A" "B $B"; do
    set -- $pair
    printf '    %s pin -> %s\n' "$1" \
      "$(tmux -L $S list-panes -a -F '#{session_name}:#{window_index} #{pane_id} pid=#{pane_pid} x=#{pane_left} w=#{pane_width} #{@pin_display}' | grep -- "$2\$" || echo '(none)')"
  done
}
echo "after bootstrap:"; report; echo
for step in "A alpha:3" "B beta:2" "A alpha:2" "B beta:3" "A alpha:1"; do
  set -- $step; cl=$A; [ "$1" = B ] && cl=$B
  tmux -L $S switch-client -c "$cl" -t "$2"; sleep 0.45
  echo "$1 -> $2"; report
done
echo
echo "reaping test: detach display B"
tmux -L $S detach-client -t "$B"; sleep 0.6
tmux -L $S list-panes -a -F '    leftover pin: #{pane_id} display=#{@pin_display}' | grep -v 'display=$' || echo "    none"
tmux -L $S kill-server 2>/dev/null || true
wait 2>/dev/null || true
