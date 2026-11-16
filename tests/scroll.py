#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The list scrolls to follow the display from session to session.

Only disposable tmux sockets, processes, and files under /tmp are mutated.

The window is too short for every session, and the display is moved natively
with `switch-client -n` and `-p`, as a key bound in tmux would. Each time, the
session it lands on must be in view and so must the one after it, so the next
switch never lands off screen; going back, the one before it as well. Before
this the list kept its place while the display walked off the bottom of it.
"""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
ROWS, COLS = 22, 60
NAMES = ['sess-%02d' % i for i in range(1, 11)]


def main():
    with tempfile.TemporaryDirectory(prefix='tmm-scroll-', dir='/tmp') as root:
        socket = root + '/socket'
        children = []
        screen = Screen(ROWS, COLS)
        ui_fd = -1

        def tmux(*args):
            run = subprocess.run(['tmux', '-S', socket, *args],
                                 capture_output=True, timeout=5)
            if run.returncode:
                raise AssertionError((args, run.stderr.decode().strip()))
            return run.stdout.decode()

        def terminal(argv):
            pid, fd = pty.fork()
            if pid == 0:
                os.environ['TERM'] = 'xterm-256color'
                os.environ.pop('TMUX', None)
                os.execvp(argv[0], argv)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
            children.append((pid, fd))
            return pid, fd

        def pump(duration=0.8):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                ready, _, _ = select.select([fd for _, fd in children], [], [], 0.03)
                for fd in ready:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        continue
                    if fd != ui_fd:
                        continue
                    screen.feed(data)
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def session_of(client):
            for row in tmux('list-clients', '-F', '#{client_name}|#{session_name}').splitlines():
                name, _, session = row.partition('|')
                if name == client:
                    return session
            raise AssertionError(('client not attached', client))

        def shown():
            """Sessions whose own row is in view. Matched by the row's shape,
            fold arrow and number then name, because the display's row names
            the session it is on too, which would always count the current
            one as shown."""
            names = []
            for line in screen.lines():
                found = re.match(r'\s*[\u25bc\u25b6] [0-9 ] (sess-\d\d)\b', line)
                if found:
                    names.append(found.group(1))
            return names

        def settle(want, what, limit=8):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.05)
                if all(n in shown() for n in want):
                    return
            raise AssertionError((what, 'wanted', want, 'shown', shown(), screen.lines()))

        try:
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', NAMES[0], '-c', root)
            for name in NAMES[1:]:
                tmux('new-session', '-d', '-s', name, '-c', root)
            terminal(['tmux', '-S', socket, 'attach-session', '-t', NAMES[0]])
            deadline = time.monotonic() + 10
            while not tmux('list-clients', '-F', '#{client_name}').strip():
                assert time.monotonic() < deadline, 'the display never attached'
                pump(0.05)
            client = tmux('list-clients', '-F', '#{client_name}').strip()
            _, ui_fd = terminal([str(BINARY), '-S', socket, '--client', client])

            settle(NAMES[:2], 'at the start')
            # The fixture is only a test if the list cannot show everything.
            assert NAMES[-1] not in shown(), ('window tall enough for every session', shown())

            # Forward through every session and round to the first again.
            for step in range(len(NAMES)):
                tmux('switch-client', '-c', client, '-n')
                here = NAMES.index(session_of(client))
                assert here == (step + 1) % len(NAMES), (step, session_of(client))
                want = [NAMES[here]] + ([NAMES[here + 1]] if here + 1 < len(NAMES) else [])
                settle(want, 'after switch-client -n to ' + NAMES[here])

            # Backward from the first wraps to the last, then walks up.
            for step in range(len(NAMES)):
                tmux('switch-client', '-c', client, '-p')
                here = NAMES.index(session_of(client))
                want = [NAMES[here]] + ([NAMES[here - 1]] if here > 0 else [])
                settle(want, 'after switch-client -p to ' + NAMES[here])

            # A wheel scroll away from the display is left alone until the
            # display moves again: following is on a move, not every frame.
            tmux('switch-client', '-c', client, '-t', NAMES[0])
            settle(NAMES[:2], 'back at the first')
            for _ in range(4):
                os.write(ui_fd, b'\x1b[<65;3;10M')
            pump(1.0)
            assert NAMES[0] not in shown(), ('the wheel did not scroll', shown())
            # A redraw with no move: a pane change elsewhere.
            tmux('new-window', '-d', '-t', NAMES[5], '-c', root)
            pump(1.5)
            assert NAMES[0] not in shown(), ('the list jumped back without a move', shown())

            print('scroll: ok')
        finally:
            for pid, fd in children:
                try:
                    os.close(fd)
                except OSError:
                    pass
            subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)
            for pid, _ in children:
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass


if __name__ == '__main__':
    main()
