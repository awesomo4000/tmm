#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The wheel scrolls tmm's own scrollback, and lines that left the screen come back.

tmm receives every byte a pane writes, including the lines that have already
scrolled out of tmux's view -- `%output` carries them whether or not tmux's
grid still holds them. So the history shown here is tmm's, not recovered from
tmux, which is why it carries everything the pane wrote rather than only what
tmux understood.

The wheel reaches it only when the program inside did not ask for mouse
reporting. A pager or an editor scrolls its own content, and a terminal that
intercepted the wheel would break it, so that case is checked too.

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
import keys  # noqa: E402

ROWS, COLS, SPLIT = 20, 120, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-scroll-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=6).decode().strip()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '10')
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

        def shows(text):
            return any(text in line for line in region())

        def until(predicate, limit=12):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def wheel(button, times=1):
            # SGR mouse, inside the region. 64 is wheel up, 65 wheel down.
            col, row = SPLIT + 5, 5
            for _ in range(times):
                os.write(fd, ('\x1b[<%d;%d;%dM' % (button, col, row)).encode())
                pump(0.12)

        try:
            pump(3.0)
            os.write(fd, keys.FOCUS)           # focus the region
            pump(0.4)
            pane = tmux('display-message', '-p', '-t', 'alpha', '#{pane_id}')

            # Enough lines that the early ones leave the screen entirely.
            tmux('send-keys', '-t', pane,
                 'for i in $(seq 1 60); do echo SCROLLMARK-$i; done', 'Enter')
            assert until(lambda: shows('SCROLLMARK-60')), \
                ('the pane output never arrived', [l for l in region() if l.strip()][-4:])
            assert not shows('SCROLLMARK-2'), \
                ('the early lines never left the screen, so nothing is being '
                 'recalled from scrollback', [l for l in region() if l.strip()][:4])

            # Wheel up: a line that had left the screen comes back.
            wheel(64, times=12)
            assert until(lambda: shows('SCROLLMARK-2'), limit=6), \
                ('scrolling back did not recall a line that had left the screen',
                 [l for l in region() if l.strip()][:6])

            # Wheel down returns to the live bottom.
            wheel(65, times=24)
            assert until(lambda: shows('SCROLLMARK-60'), limit=6), \
                ('scrolling forward did not return to the live output',
                 [l for l in region() if l.strip()][-6:])

            # A program that asked for mouse reporting gets the wheel itself,
            # so the viewport must not move. `printf` turns reporting on and
            # the shell leaves it on.
            tmux('send-keys', '-t', pane, "printf '\\033[?1000h'", 'Enter')
            pump(1.0)
            wheel(64, times=12)
            pump(0.8)
            # The test is whether the viewport moved, not whether the screen
            # changed: the forwarded wheel reaches the shell, which echoes the
            # mouse bytes at its prompt, so the text differs either way. If
            # the viewport had scrolled, a line from history would be back.
            assert not shows('SCROLLMARK-2'), \
                ('the wheel scrolled our scrollback while the program had '
                 'mouse reporting on', [l for l in region() if l.strip()][:4])
            print('ok: the wheel recalls lines that left the screen, returns '
                  'to the live bottom, and yields to a program that wants it')
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
