#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The current-pane marker follows the selected display wherever it goes.

Only disposable tmux sockets, processes, and files under /tmp are mutated.

Regression test for reading a client's position with `display-message -c`.
That looks like the way to ask where one client is, but `-c` only selects the
client for client-specific formats: the target the formats expand against is
the server's current pane. So it answers the same for every client and never
moves when a client navigates, which froze the marker on whichever pane the
server happened to consider current. `list-clients -F` expands per client.

The assertions are on the marker's row, not its text, because panes routinely
share a name and a marker "on some row showing bash" proves nothing.
"""
import fcntl
import os
from pathlib import Path
import pty
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
ROWS, COLS = 40, 60
MARKER = '▸'


def main():
    with tempfile.TemporaryDirectory(prefix='tmm-follow-', dir='/tmp') as root:
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

        def where(client):
            """The pane a client is on, asked the one way that is per client."""
            for row in tmux('list-clients', '-F', '#{client_name}|#{pane_id}').splitlines():
                name, _, pane = row.partition('|')
                if name == client:
                    return pane
            raise AssertionError(('client not attached', client))

        def marker_rows():
            return [i for i, line in enumerate(screen.lines()) if MARKER in line]

        def row_of(label):
            """The sidebar row showing `label`, which the fixture makes unique."""
            for i, line in enumerate(screen.lines()):
                if label in line:
                    return i
            raise AssertionError(('row not on screen', label, screen.lines()))

        def settle(expect_row, what, limit=8):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if marker_rows() == [expect_row]:
                    return
            raise AssertionError((what, 'marker at', marker_rows(),
                                  'expected', expect_row, screen.lines()))

        try:
            # Pane commands are made distinct so a row can be identified by
            # name; the bug being tested hid behind three panes all named bash.
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-c', root)
            tmux('new-session', '-d', '-s', 'beta', '-c', root)
            tmux('set-option', '-p', '-t', 'alpha', '@agent_hint', 'in-alpha')
            beta_first = tmux('list-panes', '-t', 'beta', '-F', '#{pane_id}').strip()
            tmux('set-option', '-p', '-t', beta_first, '@agent_hint', 'in-beta-one')
            beta_second = tmux('new-window', '-d', '-t', 'beta', '-P', '-F', '#{pane_id}',
                               '-n', 'second', '-c', root).strip()
            tmux('set-option', '-p', '-t', beta_second, '@agent_hint', 'in-beta-two')

            terminal(['tmux', '-S', socket, 'attach-session', '-t', 'alpha'])
            pump(1.5)
            client = tmux('list-clients', '-F', '#{client_name}').strip()
            _, ui_fd = terminal([str(BINARY), '-S', socket, '--client', client])
            pump(3)

            # Starting point: the display is on alpha, and so is the marker.
            assert where(client) == tmux('list-panes', '-t', 'alpha', '-F',
                                         '#{pane_id}').strip()
            settle(row_of('in-alpha'), 'initial marker')

            # 1. A switch driven from tmm: clicking a pane in another session.
            target = row_of('in-beta-one')
            os.write(ui_fd, f'\x1b[<0;3;{target + 1}M\x1b[<0;3;{target + 1}m'.encode())
            pump(1.5)
            assert where(client) == beta_first, (where(client), beta_first)
            settle(row_of('in-beta-one'), 'marker after clicking a pane in tmm')

            # 2. The user moves to another window natively. This is the one
            #    that stayed frozen: the display moved and the marker did not.
            tmux('select-window', '-t', 'beta:second')
            assert where(client) == beta_second, (where(client), beta_second)
            settle(row_of('in-beta-two'), 'marker after native select-window')

            # 3. The user moves to another pane within that window natively.
            split = tmux('split-window', '-d', '-t', beta_second, '-P', '-F',
                         '#{pane_id}', '-c', root).strip()
            tmux('set-option', '-p', '-t', split, '@agent_hint', 'in-split')
            pump(1.5)
            tmux('select-pane', '-t', split)
            assert where(client) == split, (where(client), split)
            settle(row_of('in-split'), 'marker after native select-pane')

            # 4. The user switches session natively, all the way back.
            tmux('switch-client', '-c', client, '-t', 'alpha')
            assert where(client) == tmux('list-panes', '-t', 'alpha', '-F',
                                         '#{pane_id}').strip()
            settle(row_of('in-alpha'), 'marker after native switch-client')

            print('ok')
        finally:
            subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)
            for pid, fd in children:
                try:
                    os.kill(pid, 9)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if os.waitpid(pid, os.WNOHANG)[0]:
                            break
                        time.sleep(0.05)
                except (ProcessLookupError, ChildProcessError):
                    pass
                try:
                    os.close(fd)
                except OSError:
                    pass


if __name__ == '__main__':
    main()
