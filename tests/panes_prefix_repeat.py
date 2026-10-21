#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A repeating tmux binding repeats, held open the way tmux holds it open.

The workflow this is for: prefix once, then keep ctrl down and tap hjkl to
resize a pane a column at a time. That depends on `bind -r`, which tmux
services by leaving the client's key table at `prefix` for `repeat-time`
after running the binding, so the key works again without the prefix. Every
repeat re-arms that window -- measured, not assumed: five repeats 500ms apart
all ran, across 2.5s of a 700ms window.

tmm cannot read `client_key_table` back on the key path, because that is a
`Stream.request` -- a write then a read -- and the display thread cannot do
one while the event worker shares the stream. So it mirrors the rule instead,
and asks tmux which keys repeat: `list-keys` prints a repeating binding with
`-r`, and `repeat-time` and `initial-repeat-time` come from `show-options`.

Getting this wrong is not a missing convenience. With the window unmodelled,
the second `C-h` takes the raw byte path and the pane receives 0x08; `C-j`
would deliver 0x0a to whatever is reading there, which for an agent at a
prompt is a submit. So the last case here asserts the bytes never arrive.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
ROWS, COLS = 40, 170
REPEAT_MS = 700


def answer(fd, data):
    """Reply to the queries vaxis makes, so it never waits on the harness."""
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        # This harness speaks the kitty keyboard protocol, as the
        # terminals tmm targets do. It has to: in the legacy encoding
        # ctrl+h IS byte 0x08, which is also backspace, so nothing
        # downstream can tell a `C-h` binding from a BSpace one. That is
        # a property of the wire, not of tmm.
        os.write(fd, b'\x1b[?31u')


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')

    with tempfile.TemporaryDirectory(prefix='tmm-repeat-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args, check=False):
            r = subprocess.run([TMUX, '-S', socket, *args],
                               capture_output=True, text=True, timeout=10)
            if check:
                assert r.returncode == 0, (args, r.stderr)
            return r.stdout

        # The real shape of the configuration this is for: a non-default
        # prefix, and resize bound with -r so it repeats.
        conf = os.path.join(root, 'conf')
        with open(conf, 'w') as f:
            f.write('set -g prefix C-a\n'
                    'set -g prefix2 None\n'
                    'set -g repeat-time %d\n'
                    'set -g initial-repeat-time 0\n'
                    'bind -r C-h resize-pane -L 1\n'
                    'bind -r C-l resize-pane -R 1\n'
                    # Bound WITHOUT -r, so it must close the window.
                    'bind h select-pane -L\n' % REPEAT_MS)

        tmux('-f', conf, 'new-session', '-d', '-s', 'r', '-x', '100', '-y', '30',
             check=True)
        tmux('split-window', '-h', '-t', 'r', check=True)
        panes = tmux('list-panes', '-t', 'r', '-F', '#{pane_id}').split()
        assert len(panes) == 2, panes
        left, right = panes
        tmux('select-pane', '-t', right, check=True)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    answer(fd, data)

        def width():
            return int(tmux('display-message', '-p', '-t', left,
                            '#{pane_width}').strip() or 0)

        def press(data, settle=0.3):
            os.write(fd, data)
            pump(settle)

        # Keys in the kitty encoding: CSI codepoint ; modifiers u, where the
        # ctrl bit is 4 and the base is 1. Spelled out because the legacy
        # bytes for these chords are ambiguous -- see `answer`.
        C_A = b'\x1b[97;5u'
        C_H = b'\x1b[104;5u'
        C_J = b'\x1b[106;5u'
        C_L = b'\x1b[108;5u'
        PLAIN_H = b'\x1b[104;1u'

        failures = []
        try:
            pump(3.0)
            press(b'\x00')      # ctrl+` : keyboard to the region
            pump(0.5)

            # 1. Prefix once, then the repeating key three times with no
            #    prefix in between. This is the workflow: ctrl stays down.
            start = width()
            press(C_A)              # C-a
            press(C_H)              # C-h
            press(C_H)
            press(C_H)
            pump(0.5)
            after = width()
            if start - after != 3:
                failures.append('three C-h after one prefix resized by %d '
                                'columns, not 3 (%d -> %d)'
                                % (start - after, start, after))

            # 2. The window re-arms, so a gap shorter than repeat-time keeps
            #    it open however long the whole run takes. Two keys 0.5s
            #    apart span more than the 0.7s window between them.
            start = width()
            press(C_A)
            press(C_H, settle=0.5)
            press(C_H, settle=0.5)
            press(C_H, settle=0.5)
            pump(0.4)
            after = width()
            if start - after != 3:
                failures.append('repeats 0.5s apart resized by %d columns, '
                                'not 3: the window is not re-arming'
                                % (start - after))

            # 3. And the other direction, so it is not a one-way accident.
            start = width()
            press(C_A)
            press(C_L)              # C-l
            press(C_L)
            pump(0.4)
            if width() - start != 2:
                failures.append('two C-l after one prefix resized by %d, not 2'
                                % (width() - start))

            # 4. Once the window lapses, a bare repeat key stops resizing.
            #    tmux is back in `root` and so is tmm.
            press(C_A)
            press(C_H)
            pump((REPEAT_MS / 1000.0) + 0.6)
            start = width()
            press(C_H)
            pump(0.4)
            if width() != start:
                failures.append('a bare C-h after the window lapsed still '
                                'resized (%d -> %d)' % (start, width()))

            # 5. A key bound without -r closes the window, as tmux does.
            tmux('select-pane', '-t', right, check=True)
            pump(0.3)
            press(C_A)
            press(PLAIN_H)                 # select-pane -L, no -r
            pump(0.5)
            active = tmux('display-message', '-p', '-t', 'r',
                          '#{pane_id}').strip()
            if active != left:
                failures.append('the non-repeating key did not run (active %s)'
                                % active)
            start = width()
            press(C_H)              # should NOT resize now
            pump(0.4)
            if width() != start:
                failures.append('the window stayed open after a key bound '
                                'without -r (%d -> %d)' % (start, width()))

            # 6. A repeat key itself must never reach the program. This
            #    is what makes the bug harmful rather than annoying: C-h is
            #    byte 0x08, so a repeat that falls through to the raw path
            #    backspaces over whatever is on the line.
            #
            #    Counted rather than compared, because a resize rewraps the
            #    captured text: the typed line contributes one "ZZQQ", a
            #    submit would add a second as output, and a stray backspace
            #    would destroy the first. Focus is pinned first, since
            #    earlier cases move the active pane and inspecting a pane the
            #    keyboard has left would miss the bytes rather than prove
            #    they never arrived.
            #
            #    Only the repeat keys are asserted. An unbound key that ends
            #    a repeat window IS passed to the pane, by tmux itself -- a
            #    real attached client does the same, measured side by side
            #    against `send-keys -K` -- so tmm must not swallow it.
            tmux('select-pane', '-t', right, check=True)
            pump(0.6)
            tmux('send-keys', '-t', right, 'C-u')
            pump(0.4)
            tmux('send-keys', '-t', right, 'printf ZZQQ', check=True)
            pump(0.6)
            if tmux('capture-pane', '-p', '-t', right).count('ZZQQ') != 1:
                failures.append('the harness could not set the line up')
            press(C_A)
            press(C_H)
            press(C_H)
            pump(0.8)
            seen = tmux('capture-pane', '-p', '-t', right).count('ZZQQ')
            if seen != 1:
                failures.append('a repeat sequence reached the program: '
                                '"ZZQQ" appears %d times, not once -- 0 means '
                                'a 0x08 backspaced over it, 2 means the line '
                                'was submitted' % seen)
        finally:
            os.write(fd, b'q')
            time.sleep(0.5)
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    break
                time.sleep(0.2)
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            os.close(fd)
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

        if failures:
            for f in failures:
                print('FAIL: %s' % f, file=sys.stderr)
            raise SystemExit(1)
        print('ok: a -r binding repeats without the prefix, the window '
              're-arms and then lapses, a non-repeating key closes it, and '
              'no repeat byte ever reached the program')


if __name__ == '__main__':
    main()
