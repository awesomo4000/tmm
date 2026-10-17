#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The compositor shows the session's active window, and follows a switch.

Two things were wrong before. A `%layout-change` from any window was adopted,
and a layout names only its own window's panes, so a split in a background
window replaced everything on screen with that window's panes. And a window
switch was not followed at all, because tmux reports it with
`%session-window-changed` and sends no layout: a layout is sent when one
changes, not when a client starts looking at a window.

The assertions are on which pane's output is visible, which is the only thing
that distinguishes one window from another on screen.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402

ROWS, COLS, SPLIT = 40, 160, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-cwin-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode().strip()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24')
        tmux('new-window', '-d', '-t', 'alpha')
        time.sleep(0.5)
        windows = tmux('list-windows', '-t', 'alpha', '-F', '#{window_id}').split()
        assert len(windows) == 2, ('expected two windows', windows)
        first, second = windows

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                    '--session', 'alpha', '--split', str(SPLIT)])
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
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def region():
            return [line[SPLIT + 1:] for line in display.lines()]

        def until(predicate, limit=14):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def shows(text):
            return any(text in line for line in region())

        try:
            pump(3.0)
            # Mark each window, so which one is on screen is visible.
            tmux('send-keys', '-t', '%s' % first, 'printf WINDOW-ONE-MARK', 'Enter')
            assert until(lambda: shows('WINDOW-ONE-MARK')), \
                ('the first window never appeared', [l for l in region() if l.strip()][-6:])

            # A split in the *background* window must not take the display.
            # This is what used to replace every pane on screen.
            tmux('split-window', '-d', '-t', second)
            pump(1.5)
            assert shows('WINDOW-ONE-MARK'), \
                ('a split in a background window took over the display',
                 [l for l in region() if l.strip()][-6:])

            # Switching windows is followed, and the new window's panes are
            # learned even though tmux sends no layout for the switch.
            tmux('select-window', '-t', second)
            tmux('send-keys', '-t', second, 'printf WINDOW-TWO-MARK', 'Enter')
            assert until(lambda: shows('WINDOW-TWO-MARK')), \
                ('the display did not follow a window switch',
                 [l for l in region() if l.strip()][-6:])
            assert not shows('WINDOW-ONE-MARK'), \
                ('the old window is still on screen after a switch',
                 [l for l in region() if l.strip()][-6:])

            # And back again.
            tmux('select-window', '-t', first)
            assert until(lambda: shows('WINDOW-ONE-MARK')), \
                ('switching back did not restore the first window',
                 [l for l in region() if l.strip()][-6:])
            print('ok: the active window is shown, a background split does not '
                  'steal it, and switches are followed both ways')
        finally:
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
            subprocess.call([TMUX, '-S', socket, 'kill-server'],
                            stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
