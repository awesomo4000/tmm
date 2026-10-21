#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""In `--panes` mode the sidebar navigates tmm itself.

Everywhere else tmm is a view over somebody else's tmux client: you pick a
display, and clicking a session or a pane sends *that* client somewhere. In
`--panes` mode there is no such client, because tmm is the one drawing the
panes -- and the sidebar still demanded one, so clicking a pane reported
"Select a display first" and did nothing at all. That is unusable for the
case the mode exists for: driving your own session with kitty support.

So in this mode a click runs the commands a tmux binding would run,
`switch-client`, `select-window` and `select-pane`, against tmm's own control
client. tmux answers with `%session-changed`, `%session-window-changed` and
`%window-pane-changed`, all of which the compositor already follows, so tmux
stays the one deciding and tmm finds out rather than assuming.

Two sessions, because switching within one proves nothing: the point is that
the session tmm composites can be changed from the sidebar.

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402


def answer(fd, data):
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        os.write(fd, b'\x1b[?31u')


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')

    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-navigate-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args, check=False):
            r = subprocess.run([TMUX, '-S', socket, *args],
                               capture_output=True, text=True, timeout=15)
            if check:
                assert r.returncode == 0, (args, r.stderr)
            return r.stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '100', '-y', '30', check=True)
        tmux('send-keys', '-t', 'alpha', 'echo MARK_ALPHA', 'Enter')
        tmux('new-session', '-d', '-s', 'bravo', '-x', '100', '-y', '30',
             check=True)
        tmux('send-keys', '-t', 'bravo', 'echo MARK_BRAVO', 'Enter')
        time.sleep(1.2)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        display = Screen(ROWS, COLS)

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    display.feed(data)
                    answer(fd, data)

        def lines():
            return list(display.lines())

        def region():
            # Past the widest sidebar this layout uses, so only the
            # composited panes are read.
            return '\n'.join(line[20:] for line in lines())

        def client_session():
            out = tmux('list-clients', '-F', '#{client_session}').strip()
            return out.split('\n')[0] if out else ''

        def row_of(prefix, after=0):
            for n, line in enumerate(lines()):
                if n >= after and line.startswith(prefix):
                    return n
            return None

        def click(col, row):
            os.write(fd, ('\x1b[<0;%d;%dM' % (col, row + 1)).encode())
            pump(0.4)
            os.write(fd, ('\x1b[<0;%d;%dm' % (col, row + 1)).encode())
            pump(2.0)

        try:
            pump(5.0)
            start = client_session()
            if 'MARK_BRAVO' in region():
                failures.append('the harness started on bravo, so switching '
                                'to it would prove nothing')

            # The pane row under the bravo heading: an indented row, which is
            # how the sidebar draws a pane under its session.
            heading = row_of('bravo')
            if heading is None:
                failures.append('no bravo session row in the sidebar: %r'
                                % [l[:20] for l in lines() if l.strip()])
            else:
                pane_row = None
                for n in range(heading + 1, ROWS):
                    line = lines()[n]
                    if line.startswith('    ') and line[:16].strip():
                        pane_row = n
                        break
                if pane_row is None:
                    failures.append('no pane row under the bravo heading')
                else:
                    click(6, pane_row)
                    if client_session() != 'bravo':
                        failures.append('clicking a pane did not move the '
                                        'client: session is %s, was %s'
                                        % (client_session(), start))
                    if 'MARK_BRAVO' not in region():
                        failures.append('the region did not follow the click: '
                                        '%r' % region().strip()[:200])
                    if any('Select a display' in l for l in lines()):
                        failures.append('the sidebar still asked for a '
                                        'display in --panes mode')

            # And back, so it is not a one-way accident.
            heading = row_of('alpha')
            if heading is not None:
                pane_row = None
                for n in range(heading + 1, ROWS):
                    line = lines()[n]
                    if line.startswith('    ') and line[:16].strip():
                        pane_row = n
                        break
                if pane_row is not None:
                    click(6, pane_row)
                    if client_session() != 'alpha':
                        failures.append('clicking back did not move the '
                                        'client: session is %s'
                                        % client_session())
                    if 'MARK_ALPHA' not in region():
                        failures.append('the region did not follow the click '
                                        'back: %r' % region().strip()[:200])
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
    print('ok: clicking a pane in --panes navigates tmm own client to that '
          'session and window, both ways, with no display to select')


if __name__ == '__main__':
    main()
