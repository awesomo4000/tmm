#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Hover is a bar in the gutter, not a recoloured line, and ends when the
pane loses focus; a lone display is selected without being asked for.

Two tmm runs against one disposable server:

- The first starts with no display attached. When one attaches it is the only
  choice, so it is selected: its row wears the selection bar and `blink`, which
  only shows for a selected display, appears.
- The second starts with that display already attached and selects it at once.
  Then the pointer hovers a session row, which must get the bar in the gutter
  and keep its own background, and a focus-out report (what a terminal sends
  when the pane loses focus) must take the bar away.

Colours are read per cell from the screen model.

Only disposable tmux sockets and files under /tmp are mutated.
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

ROWS, COLS = 40, 60
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
BAR = '▎'


def spawn(argv, rows, cols):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ.pop('TMUX', None)
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    return pid, fd


def stop(pid, fd):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    os.close(fd)


class Ui:
    def __init__(self, socket):
        self.pid, self.fd = spawn([str(BINARY), '-S', socket], ROWS, COLS)
        self.display = Screen(ROWS, COLS)

    def pump(self, duration):
        until_ = time.monotonic() + duration
        while time.monotonic() < until_:
            for _ in select.select([self.fd], [], [], 0.02)[0]:
                try:
                    data = os.read(self.fd, 1 << 16)
                except OSError:
                    return
                self.display.feed(data)
                if b'\x1b[c' in data or b'\x1b[0c' in data:
                    os.write(self.fd, b'\x1b[?1;2c')
                if b'\x1b[5n' in data:
                    os.write(self.fd, b'\x1b[0n')

    def until(self, predicate, limit=10):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            self.pump(0.05)
            if predicate():
                return True
        return False

    def row_of(self, text):
        for r, line in enumerate(self.display.lines()):
            if line[1:].strip().startswith(text):
                return r
        return None

    def fill(self, text):
        """The background behind the first letter of the row starting `text`."""
        r = self.row_of(text)
        return 'not drawn' if r is None else self.display.background(r, 1)

    def gutter(self, text):
        """What the gutter left of the row starting `text` holds."""
        r = self.row_of(text)
        return 'not drawn' if r is None else self.display.grid[r][0]

    def shows(self, text):
        return any(text in l for l in self.display.lines())


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-hover-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'beta', '-x', '80', '-y', '24')
        client = None
        uis = []
        try:
            first = Ui(socket)
            uis.append(first)
            if not first.until(lambda: first.shows('no attached displays')):
                failures.append('the first run never drew its empty display list')
            if first.shows('blink'):
                failures.append('a display was selected before any attached')
            client = spawn([TMUX, '-S', socket, 'attach', '-t', 'alpha'], 24, 80)
            if not first.until(lambda: first.shows('blink')):
                failures.append('the first display to attach was not selected: %r'
                                % first.display.lines())
            stop(first.pid, first.fd)
            uis.remove(first)

            second = Ui(socket)
            uis.append(second)
            if not second.until(lambda: second.shows('blink')):
                failures.append('the one attached display was not selected at launch: %r'
                                % second.display.lines())
            # The selected display's session carries the selection bar.
            if not second.until(lambda: second.fill('▼ alpha') not in (None, 'not drawn')):
                failures.append('the selected session had no selection fill: %r'
                                % (second.fill('▼ alpha'),))
            row = second.row_of('▼ beta')
            if row is None:
                failures.append('the beta session never drew')
            else:
                os.write(second.fd, b'\x1b[<35;4;%dM' % (row + 1))
                if not second.until(lambda: second.gutter('▼ beta') == BAR):
                    failures.append('hover did not draw the bar: %r'
                                    % (second.gutter('▼ beta'),))
                if second.fill('▼ beta') is not None:
                    failures.append('hover recoloured the line: %r'
                                    % (second.fill('▼ beta'),))
                if second.gutter('▼ alpha') == BAR:
                    failures.append('the bar was drawn on a row the pointer is not on')
                os.write(second.fd, b'\x1b[O')
                if not second.until(lambda: second.gutter('▼ beta') == ' '):
                    failures.append('losing focus did not clear the hover: %r'
                                    % (second.gutter('▼ beta'),))
        finally:
            for ui in uis:
                stop(ui.pid, ui.fd)
            if client:
                stop(*client)
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: a lone display is selected, hover is a gutter bar, and '
          'losing focus clears it')


if __name__ == '__main__':
    main()
