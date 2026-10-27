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
# The current pane's mark: the half circle on the selected session's bar,
# bright. The pointer or cursor gets the same half circle dimmed.
MARKER = '\ue0b4'
SELECTED = ('rgb', 72, 214, 176)


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
            """Rows with the current-pane marker, among the sessions below
            their heading."""
            lines = screen.lines()
            start = next((i for i, l in enumerate(lines) if l[1:].startswith('sessions')), len(lines))
            return [i for i, line in enumerate(lines) if i > start and line[1:2] == MARKER
                    and screen.colour(i, 1) == SELECTED]

        def row_of(label, limit=15):
            """The sidebar row showing `label`, which the fixture makes unique.

            Waited for rather than read once. The first snapshot can take
            longer than any fixed pause on a loaded machine: a single read
            three seconds after launch failed in a full suite run, right after
            a test that spawns dozens of processes, and passed alone.
            """
            deadline = time.monotonic() + limit
            while True:
                for i, line in enumerate(screen.lines()):
                    if label in line:
                        return i
                if time.monotonic() >= deadline:
                    raise AssertionError(('row not on screen', label, screen.lines()))
                pump(0.05)

        def settle(expect_row, what, limit=8):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.05)
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
            deadline = time.monotonic() + 10
            while not tmux('list-clients', '-F', '#{client_name}').strip():
                assert time.monotonic() < deadline, 'the display never attached'
                pump(0.05)
            client = tmux('list-clients', '-F', '#{client_name}').strip()
            _, ui_fd = terminal([str(BINARY), '-S', socket, '--client', client])

            # Starting point: the display is on alpha, and so is the marker.
            assert where(client) == tmux('list-panes', '-t', 'alpha', '-F',
                                         '#{pane_id}').strip()
            settle(row_of('in-alpha'), 'initial marker')

            # 1. A switch driven from tmm: clicking a pane in another session.
            target = row_of('in-beta-one')
            os.write(ui_fd, f'\x1b[<0;3;{target + 1}M\x1b[<0;3;{target + 1}m'.encode())
            deadline = time.monotonic() + 10
            while where(client) != beta_first and time.monotonic() < deadline:
                pump(0.05)
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
            row_of('in-split')
            tmux('select-pane', '-t', split)
            assert where(client) == split, (where(client), split)
            settle(row_of('in-split'), 'marker after native select-pane')

            # 4. The user switches session natively, all the way back.
            tmux('switch-client', '-c', client, '-t', 'alpha')
            assert where(client) == tmux('list-panes', '-t', 'alpha', '-F',
                                         '#{pane_id}').strip()
            settle(row_of('in-alpha'), 'marker after native switch-client')

            # An agent in a session no client is attached to is still watched.
            # Agent capture is skipped for a pane that produced no output, and
            # %output only arrives for the session the control client attached
            # to, so a pane anywhere else used to keep its first verdict for
            # the rest of the run while a fresh --dump saw the truth.
            fake = Path(root) / 'screen.txt'
            program = Path(root) / 'screen.py'
            program.write_text(
                "import pathlib,sys,time\n"
                "p=pathlib.Path(sys.argv[1])\nold=None\n"
                "while True:\n text=p.read_text()\n"
                " if text!=old:\n"
                "  sys.stdout.write('\\x1b[2J\\x1b[H'+text);sys.stdout.flush();old=text\n"
                " time.sleep(.05)\n")
            quiet = '\u203a Ask Codex\n50% context left\n'
            fake.write_text(quiet)
            # beta_second is in beta; the client and so the control client are
            # on alpha by now, which is the case that used to freeze.
            tmux('set-option', '-p', '-t', beta_second, '@agent_hint', 'codex')
            tmux('respawn-pane', '-k', '-t', beta_second, 'python3',
                 str(program), str(fake))

            def glyph():
                """The status glyph on the watched agent's row, if drawn."""
                for line in screen.lines():
                    if 'codex' in line:
                        # Column 0 is the hover gutter.
                        parts = line[1:].split()
                        return parts[0] if parts else ''
                return None

            def wait_glyph(want, what, limit=10):
                deadline = time.monotonic() + limit
                while time.monotonic() < deadline:
                    pump(0.05)
                    if glyph() == want:
                        return
                raise AssertionError((what, 'glyph is', glyph(),
                                      'expected', want, screen.lines()))

            # Give the first verdict time to land and its capture budget time
            # to run out, which is the state the freeze showed up in. A fixed
            # wait on purpose: three samples at the 500 ms heartbeat, plus
            # margin. Nothing on screen says the budget is spent.
            wait_glyph('\u25cb', 'agent in another session never got a verdict')
            pump(2.0)
            fake.write_text('\u2022 Working (2s \u2022 esc to interrupt)\n' + quiet)
            wait_glyph('\u25cf', 'working was not shown for an agent in another session')
            fake.write_text(quiet)
            wait_glyph('\u2713', 'completion was not shown for an agent in another session')

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
