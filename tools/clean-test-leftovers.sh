#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Remove what a killed test run leaves behind.
#
# The suites create their sockets and directories under /tmp with
# tempfile.TemporaryDirectory, which cleans up when a test exits normally and
# not when one is killed by a timeout. Iterating on a failing test therefore
# accumulates tmux servers and nested tmm processes, and those distort the
# next measurement: a run started straight after a dirty suite reported a
# 52ms worst-case keystroke where the same build on a clean machine reports
# 0.4ms, which looked exactly like a regression and was not.
#
# Only sockets and directories under /tmp whose names the suites generate are
# touched. A tmm or tmux a person is running has no such path on its command
# line and is left alone.
set -u
# Globs rather than an enumeration of test names: the suites have used many
# prefixes over time (tmm-kitty, tmm-viq, tmm-stale and more), and a list goes
# stale silently, which is how 48 directories survived the first version of
# this. `/tmp/tmm-*` is specific enough to be ours, and the other patterns are
# the non-tmm prefixes the suites use. `/tmp/tmm` without a suffix is never
# matched.
globs="/tmp/tmm-* /tmp/recon-* /tmp/recon-stress-* /tmp/uaf-* /tmp/seq-*
/tmp/nfloor-* /tmp/pty-floor-* /tmp/tmux-floor-* /tmp/freq-* /tmp/warm-*
/tmp/img-* /tmp/rel-*"

killed=0
for pattern in $globs; do
    for dir in $pattern; do
        [ -d "$dir" ] || continue
        # Any socket the suites create, whatever they named it.
        for sock in "$dir"/socket "$dir"/sock "$dir"/sock-* "$dir"/*.sock; do
            [ -e "$sock" ] || continue
            tmux -S "$sock" kill-server 2>/dev/null && killed=$((killed + 1))
        done
    done
done

# Then the same sweep by command line, which catches the two cases the walk
# above cannot see at all:
#
#   - a server whose socket is not named `socket`, `sock` or `*.sock`. The
#     enumeration above is the very thing the comment on `globs` warns about,
#     one level down, and an older latency harness used `outer`.
#   - a server whose directory is already gone. TemporaryDirectory removes the
#     directory when the harness exits, but a tmux server started inside it
#     keeps running on the now-unlinked socket path, so there is no directory
#     left to find it through.
#
# The second one is not hypothetical: an orphan from the previous day was
# still running and turned a worst-case keystroke of 0.5ms into 77ms, which
# reads exactly like a latency regression and is not one.
#
# A test socket path on the command line is what keeps a person's own tmux out
# of this, the same rule the tmm sweep below uses.
for pid in $(pgrep -f "tmux -S /tmp/tmm-" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null && killed=$((killed + 1))
done
for pattern in recon uaf seq nfloor pty-floor tmux-floor freq warm img rel; do
    for pid in $(pgrep -f "tmux -S /tmp/$pattern-" 2>/dev/null); do
        kill -TERM "$pid" 2>/dev/null && killed=$((killed + 1))
    done
done

# A nested tmm from the nesting test holds a test socket on its command line.
# Matching on that is what keeps a person's own tmm out of this: a tmm started
# by hand has no /tmp test socket in its arguments.
for pid in $(pgrep -f "zig-out/bin/tmm .*-S /tmp/tmm-" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null && killed=$((killed + 1))
done
sleep 1
for pid in $(pgrep -f "zig-out/bin/tmm .*-S /tmp/tmm-" 2>/dev/null); do
    kill -KILL "$pid" 2>/dev/null
done

removed=0
for pattern in $globs; do
    for dir in $pattern; do
        [ -d "$dir" ] || continue
        rm -rf "$dir" && removed=$((removed + 1))
    done
done

echo "cleaned: $killed process(es), $removed directory(ies)"
