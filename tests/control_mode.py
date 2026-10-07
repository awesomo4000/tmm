#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""End-to-end check of the control-mode parser against a live tmux.

Only disposable tmux sockets and files under a temporary directory are mutated.
Runs the cmprobe binary against a throwaway server, drives tmux through the
notifications the compositor depends on, and asserts the parsed event stream.
"""
import os
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, 'zig-out', 'bin', 'cmprobe')


def main():
    if not os.path.exists(PROBE):
        sys.exit('missing %s - run: zig build' % PROBE)

    with tempfile.TemporaryDirectory(prefix='tmm-control-') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.check_output(
                ['tmux', '-S', socket, *args],
                stderr=subprocess.PIPE, timeout=5,
            ).decode()

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24', 'sleep 120')

        events_path = os.path.join(root, 'events.txt')
        with open(events_path, 'wb') as sink:
            probe = subprocess.Popen(
                [PROBE, '-S', socket, '-t', 'alpha', '--events', '40'],
                stdout=sink, stderr=subprocess.STDOUT,
            )
            try:
                time.sleep(1.0)
                tmux('new-window', '-d', '-t', 'alpha', 'sleep 120')
                marker = 'HELLO-FROM-PANE'
                tmux('split-window', '-d', '-t', 'alpha:1',
                     "printf %s; sleep 120" % shlex.quote(marker + '\n'))
                tmux('rename-window', '-t', 'alpha:1', 'renamed')
                time.sleep(1.2)
                tmux('kill-server')
                probe.wait(timeout=10)
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait(timeout=5)

        with open(events_path) as fh:
            lines = [l.rstrip('\n') for l in fh if l.strip()]

    assert lines, 'probe produced no events'
    assert not any('panic' in l or 'error:' in l for l in lines), \
        'probe reported a failure:\n' + '\n'.join(lines)

    tags = [l.split('\t')[0] for l in lines]
    rows = [l.split('\t') for l in lines]

    # Guard blocks: the attach reply is wrapped and must parse as a pair.
    assert 'reply_begin' in tags, tags
    begin = rows[tags.index('reply_begin')]
    end = rows[tags.index('reply_end')]
    assert begin[1] == end[1], 'guard numbers differ: %s vs %s' % (begin, end)
    assert end[2] == 'ok', end

    # Session identity. tmux session ids are literally "$N".
    sess = rows[tags.index('session_changed')]
    assert sess[1].startswith('$') and sess[2] == 'alpha', sess

    # Window lifecycle and rename.
    assert 'window_add' in tags, tags
    assert rows[tags.index('window_add')][1].startswith('@'), rows
    assert 'window_renamed' in tags, tags

    # Layout: classic v1 string, not the opt-in JSON form.
    layout = rows[tags.index('layout_change')]
    assert layout[1].startswith('@'), layout
    assert ',' in layout[2] and 'x' in layout[2], layout
    assert not layout[2].lstrip().startswith('{"'), \
        'got new-layouts JSON, expected classic v1: %s' % layout[2]

    # Pane output: decoded back to exact bytes, CRLF included.
    outs = [r for r in rows if r[0] == 'output']
    assert outs, 'no %output events'
    assert any('HELLO-FROM-PANE\\x0d\\x0a' in r[2] for r in outs), outs

    # Killing the server ends the stream cleanly.
    assert tags[-1] == 'exit', tags

    print('control-mode OK: %d events, tags=%s' % (len(lines), ','.join(tags)))


if __name__ == '__main__':
    main()
