#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Report what this program is doing, so tmm shows it instead of guessing.
#
# Writes one OSC 7501 record to the tty of the tmux pane this process is in.
# tmux reads the pane output, tmm parses the sequence out of it, and the
# sidebar row for that pane shows the reported state. A terminal that does not
# know OSC 7501 ignores it, so this is safe to leave installed anywhere.
#
# tmm only reads pane output in compositor mode, so a report lands nowhere
# unless tmm is running `--panes` on this server. That is a no-op, not an
# error: this exits 0 and silently with no tmux, with a stale pane id, and
# with nothing reading the pane.
#
# Usage:
#   tmm-report.sh state=working app=cargo progress=40
#   tmm-report.sh state=blocked kind=permission
#   tmm-report.sh state=clear
#
# Every argument is one `key=value` option. The vocabulary is tmm's: state is
# idle, working, done, blocked, error or clear; kind is permission, question
# or auth; progress is 0 to 100; id names a sub-record, with `/` nesting it
# under a parent. A report REPLACES the whole record, so send every field you
# want kept, every time.
#
# `title` and `msg` are given as plain text here and base64 encoded on the
# way out, which is what the protocol requires of them. That is worth doing
# in one place: text that is not valid base64 does not merely lose the field,
# it makes the whole record invalid, so a caller that sent a bare title would
# silently report nothing at all.
#
# Why the pane tty rather than this process's own stdout: a program invoked
# from an agent hook has neither. Claude Code command hooks run in their own
# session with no controlling terminal -- `/dev/tty` cannot be opened -- and
# their stdout is captured by the agent rather than written to the terminal.
# What a hook does inherit is `$TMUX` and `$TMUX_PANE`, which is enough to ask
# tmux where the pane is and write there directly. Verified both ways: the
# open of `/dev/tty` fails, and a write to `#{pane_tty}` from a process with no
# controlling terminal arrives as pane output.

set -u

[ "$#" -gt 0 ] || { echo "usage: $0 state=working [key=value ...]" >&2; exit 2; }

# Nothing to report to if this is not running inside tmux. Not an error: the
# same hook config is used outside tmm, where this should do nothing at all.
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

# `$TMUX` is "socket,pid,session". The socket matters: tmm may well be watching
# a server that is not the default one, and a bare `tmux` would address the
# wrong server or start one.
socket=${TMUX%%,*}
tmux_bin=${TMM_REPORT_TMUX:-tmux}

tty=$("$tmux_bin" -S "$socket" display -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null) || exit 0
[ -n "$tty" ] || exit 0
[ -w "$tty" ] || exit 0

# Options joined by `:`, which is the record separator OSC 7501 uses.
payload=""
for opt in "$@"; do
    case "$opt" in
        *=*) ;;
        # Refused rather than sent: an option without `=` would be parsed as a
        # key with an empty value and silently overwrite a field.
        *) echo "$0: not a key=value option: $opt" >&2; exit 2 ;;
    esac
    key=${opt%%=*}
    value=${opt#*=}
    case "$key" in
        title|msg)
            # `tr -d` because GNU base64 wraps at 76 columns and a newline in
            # the middle of an OSC terminates it early.
            value=$(printf '%s' "$value" | base64 | tr -d '\n') || exit 0
            opt="$key=$value"
            ;;
    esac
    if [ -z "$payload" ]; then payload=$opt; else payload="$payload:$opt"; fi
done

# One write, so the sequence cannot be torn in half by another process writing
# to the same pane between the introducer and the terminator.
printf '\033]7501;%s\033\\' "$payload" > "$tty" 2>/dev/null || exit 0
