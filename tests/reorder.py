#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Sessions can be put in any order by dragging them, or with Shift-J and
Shift-K, for as long as tmm runs.

Against one disposable server with sessions alpha, beta and gamma, listed in
that order to begin with:

- Dragging gamma's name up onto alpha puts gamma first, and the drag does not
  also count as a click, which would open the rename field.
- Dragging by a pane row moves its whole session the same way, and is not
  also a click on the pane: with no display attached, that click would say
  to select one.
- A drag that Escape interrupts puts the session back where it was.
- Shift-J moves the session under the cursor down one place, and Shift-K
  back up.
- A session created afterwards goes to the bottom, leaving the arranged
  order alone.

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


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-reorder-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'beta', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'gamma', '-x', '80', '-y', '24')

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
        display = Screen(ROWS, COLS)

        def pump(duration):
            until_ = time.monotonic() + duration
            while time.monotonic() < until_:
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

        def until(predicate, limit=10):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.05)
                if predicate():
                    return True
            return False

        def listed():
            """Session names top to bottom, past the gutter and fold arrow."""
            names = []
            for line in display.lines():
                body = line[1:]
                if body.startswith('▼ ') or body.startswith('▶ '):
                    names.append(body[2:].split()[0])
            return names

        def row_of(name):
            """The 1-based screen row of a session's name."""
            for r, line in enumerate(display.lines()):
                body = line[1:]
                if (body.startswith('▼ ') or body.startswith('▶ ')) and body[2:].split()[:1] == [name]:
                    return r + 1
            return None

        def mouse(button, row, final, col=6):
            os.write(fd, b'\x1b[<%d;%d;%d%s' % (button, col, row, final))
            pump(0.05)

        def drag(name, onto, escape=False, by_pane=False):
            # A session's first pane is the row under its name.
            start, end = row_of(name) + (1 if by_pane else 0), row_of(onto)
            mouse(0, start, b'M')
            step = -1 if end < start else 1
            for row in range(start + step, end + step, step):
                mouse(32, row, b'M')
            if escape:
                os.write(fd, b'\x1b')
                pump(0.05)
            mouse(0, end, b'm')

        try:
            if not until(lambda: listed() == ['alpha', 'beta', 'gamma']):
                failures.append('the sessions never listed in server order: %r' % listed())
            drag('gamma', 'alpha')
            if not until(lambda: listed() == ['gamma', 'alpha', 'beta']):
                failures.append('dragging gamma onto alpha did not put it first: %r' % listed())
            pump(0.3)
            if any('Enter save' in l for l in display.lines()):
                failures.append('the drag also opened the rename field')

            drag('beta', 'gamma', by_pane=True)
            if not until(lambda: listed() == ['beta', 'gamma', 'alpha']):
                failures.append('dragging by a pane did not move its session: %r' % listed())
            pump(0.3)
            if any('Select a display first' in l for l in display.lines()):
                failures.append('the drag by a pane also clicked the pane')
            drag('beta', 'alpha')
            if not until(lambda: listed() == ['gamma', 'alpha', 'beta']):
                failures.append('dragging beta back below alpha failed: %r' % listed())

            drag('beta', 'gamma', escape=True)
            pump(0.3)
            if listed() != ['gamma', 'alpha', 'beta']:
                failures.append('Escape did not put the dragged session back: %r' % listed())

            # Hover alpha so the cursor is on it, then move it with the keys.
            mouse(35, row_of('alpha'), b'M')
            os.write(fd, b'J')
            if not until(lambda: listed() == ['gamma', 'beta', 'alpha']):
                failures.append('Shift-J did not move the session down: %r' % listed())
            os.write(fd, b'K')
            if not until(lambda: listed() == ['gamma', 'alpha', 'beta']):
                failures.append('Shift-K did not move the session up: %r' % listed())

            tmux('new-session', '-d', '-s', 'aardvark', '-x', '80', '-y', '24')
            if not until(lambda: listed() == ['gamma', 'alpha', 'beta', 'aardvark']):
                failures.append('a new session did not go to the bottom: %r' % listed())
        finally:
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
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: sessions reorder by drag and by Shift-J/K, Escape cancels, '
          'and new ones go to the bottom')


if __name__ == '__main__':
    main()
