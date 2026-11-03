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
- [sort], and the s key, put the sessions back in the server's order, which
  is the order tmux's own next and previous session keys step through.
- The mark after [sort], and the a key, step from M, manual, to A,
  automatic, which keeps them in that order, a new session going in
  by name, until a drag or Shift-J/K moves one, which puts it back
  to M. Escape during a drag puts the A back with the session.

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

        def name_in(body):
            """A session row's name: after the arrow, and after the number key
            the first ten carry."""
            words = body[2:].split()
            return words[1] if words and words[0].isdigit() else words[0]

        def listed():
            """Session names top to bottom, past the gutter and fold arrow."""
            names = []
            for line in display.lines():
                body = line[1:]
                if body.startswith('▼ ') or body.startswith('▶ '):
                    names.append(name_in(body))
            return names

        def row_of(name):
            """The 1-based screen row of a session's name."""
            for r, line in enumerate(display.lines()):
                body = line[1:]
                if (body.startswith('▼ ') or body.startswith('▶ ')) and name_in(body) == name:
                    return r + 1
            return None

        def mouse(button, row, final, col=6):
            os.write(fd, b'\x1b[<%d;%d;%d%s' % (button, col, row, final))
            pump(0.05)

        def drag(name, onto, escape=False, by_pane=False):
            # A session's first pane is the row under its name.
            # Both rows on screen first: a frame being redrawn can miss one.
            until(lambda: row_of(name) is not None and row_of(onto) is not None)
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

            # [sort] puts them back in the server's order, the one tmux's own
            # next and previous session keys step through.
            heading = next(r for r, l in enumerate(display.lines()) if '[sort]' in l)
            column = display.lines()[heading].index('[sort]') + 2
            mouse(0, heading + 1, b'M', col=column)
            mouse(0, heading + 1, b'm', col=column)
            if not until(lambda: listed() == ['aardvark', 'alpha', 'beta', 'gamma']):
                failures.append('[sort] did not list the sessions as tmux orders them: %r' % listed())
            if any('Enter save' in l for l in display.lines()):
                failures.append('[sort] also opened the new session field')

            drag('gamma', 'aardvark')
            if not until(lambda: listed() == ['gamma', 'aardvark', 'alpha', 'beta']):
                failures.append('dragging after a sort failed: %r' % listed())
            os.write(fd, b's')
            if not until(lambda: listed() == ['aardvark', 'alpha', 'beta', 'gamma']):
                failures.append('s did not sort the sessions: %r' % listed())

            # The mark after [sort] steps from M, manual, the order as
            # arranged, to A, automatic, following the server: a new session then goes
            # in by name, where tmux will step to it, not at the bottom.
            def heading():
                return next(r for r, l in enumerate(display.lines()) if '[sort]' in l)

            def automatic():
                return '[sort] Ⓐ' in display.lines()[heading()]

            def click_box():
                row = heading()
                column = display.lines()[row].index('[sort]') + len('[sort] ') + 1
                mouse(0, row + 1, b'M', col=column)
                mouse(0, row + 1, b'm', col=column)

            if '[sort] Ⓜ' not in display.lines()[heading()]:
                failures.append('the mark after [sort] did not start as M: %r'
                                % display.lines()[heading()])
            click_box()
            if not until(automatic):
                failures.append('clicking M did not make it A')
            tmux('new-session', '-d', '-s', 'bongo', '-x', '80', '-y', '24')
            if not until(lambda: listed() == ['aardvark', 'alpha', 'beta', 'bongo', 'gamma']):
                failures.append('with A on, a new session did not go in by name: %r' % listed())

            # Escape puts the session and the A back.
            drag('gamma', 'aardvark', escape=True)
            pump(0.3)
            if listed() != ['aardvark', 'alpha', 'beta', 'bongo', 'gamma'] or not automatic():
                failures.append('Escape did not restore the sorted order and the A: %r %r'
                                % (listed(), automatic()))

            # Moving a session is choosing an order: it goes back to M, and
            # the list stays where it was put.
            drag('gamma', 'aardvark')
            if not until(lambda: listed()[0] == 'gamma' and not automatic()):
                failures.append('a drag did not go back to M: %r %r' % (listed(), automatic()))
            tmux('new-session', '-d', '-s', 'apple', '-x', '80', '-y', '24')
            if not until(lambda: listed() == ['gamma', 'aardvark', 'alpha', 'beta', 'bongo', 'apple']):
                failures.append('on M, a new session did not go to the bottom: %r' % listed())

            os.write(fd, b'a')
            if not until(lambda: automatic() and listed() == ['aardvark', 'alpha', 'apple', 'beta', 'bongo', 'gamma']):
                failures.append('a did not switch to A and sort: %r %r' % (listed(), automatic()))
            os.write(fd, b'a')
            if not until(lambda: not automatic()):
                failures.append('a did not switch back to M')
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
          'new ones go to the bottom, [sort] and s restore the tmux order, '
          'and auto keeps it until a session is moved')


if __name__ == '__main__':
    main()
