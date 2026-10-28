#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""`1` to `9` and `0` switch the selected display to the first ten sessions
as tmm lists them, and `?` opens a panel of the key bindings.

Against one disposable server with sessions alpha, beta and gamma and one
display attached to alpha:

- `?` opens the panel and `?` closes it again; Escape closes it too, and so
  does `q`, which while the panel is open does not quit.
- `2` sends the display to beta, the second session listed.
- After gamma is dragged to the top, the numbers shown beside the names read
  1 gamma, 2 alpha, 3 beta, and `1` sends the display to gamma and `3` to
  beta: they count the list as arranged, not the server's own order.
- `j` and `k` step between sessions only, never stopping on a pane, and
  Enter switches the display to the session they land on. With every
  session folded they still do, and the cursor shows beside the name.

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
HOVER, SELECTED = ('rgb', 58, 96, 90), ('rgb', 72, 214, 176)
ASH = ('rgb', 112, 118, 132)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-keys-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'beta', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'gamma', '-x', '80', '-y', '24')
        # One display, on alpha; as the only one it is selected at launch.
        cpid, cfd = pty.fork()
        if cpid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(TMUX, [TMUX, '-S', socket, 'attach', '-t', 'alpha'])
        fcntl.ioctl(cfd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))

        def on():
            """The display's session; tmm's own control-mode clients are
            listed too, and skipped."""
            lines = tmux('list-clients', '-F', '#{client_control_mode} #{session_name}').split('\n')
            return next((l.split(' ', 1)[1] for l in lines if l.startswith('0 ')), None)

        def drain_client():
            while select.select([cfd], [], [], 0)[0]:
                try:
                    os.read(cfd, 1 << 16)
                except OSError:
                    return

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
                drain_client()
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
            if not until(lambda: listed() == ['alpha', 'beta', 'gamma'] and any('➤' in l for l in display.lines())):
                failures.append('the sessions and the selected display never showed: %r' % display.lines())

            def panel():
                return any('switch to session 1 to 10' in l for l in display.lines())
            os.write(fd, b'?')
            if not until(panel):
                failures.append('? did not open the keys panel')
            os.write(fd, b'?')
            if not until(lambda: not panel()):
                failures.append('? did not close the keys panel')
            os.write(fd, b'?')
            until(panel)
            os.write(fd, b'\x1b')
            if not until(lambda: not panel()):
                failures.append('Escape did not close the keys panel')
            # q closes an open panel and leaves tmm running.
            os.write(fd, b'?')
            until(panel)
            os.write(fd, b'q')
            if not until(lambda: not panel()):
                failures.append('q did not close the keys panel')
            pump(0.3)
            if os.waitpid(pid, os.WNOHANG) != (0, 0):
                failures.append('q with the keys panel open quit tmm')

            os.write(fd, b'2')
            if not until(lambda: on() == 'beta'):
                failures.append('2 did not switch the display to beta: %r' % on())

            drag('gamma', 'alpha')
            until(lambda: listed() == ['gamma', 'alpha', 'beta'])
            # The number keys are shown beside the names, in listed order and
            # their own quiet colour.
            numbered = [(l[3:4], name_in(l[1:]), display.colour(r, 3))
                        for r, l in enumerate(display.lines()) if l[1:3] in ('▼ ', '▶ ')]
            want = [('1', 'gamma', ASH), ('2', 'alpha', ASH), ('3', 'beta', ASH)]
            if numbered != want:
                failures.append('the session numbers did not follow the order: %r' % numbered)
            os.write(fd, b'1')
            if not until(lambda: on() == 'gamma'):
                failures.append('1 did not follow the arranged order to gamma: %r' % on())
            os.write(fd, b'3')
            if not until(lambda: on() == 'beta'):
                failures.append('3 did not follow the arranged order to beta: %r' % on())

            # The drag left the cursor on gamma. j steps to the next session,
            # alpha, past gamma's pane, and Enter switches to it; stopping on
            # the pane would have sent the display to gamma instead.
            os.write(fd, b'j\r')
            if not until(lambda: on() == 'alpha'):
                failures.append('j and Enter did not go to the next session: %r' % on())
            os.write(fd, b'k\r')
            if not until(lambda: on() == 'gamma'):
                failures.append('k and Enter did not go to the previous session: %r' % on())

            # With every session folded, j and k still step between them, and
            # the cursor shows as the dim bar beside the folded name, since
            # there are no panes for it to run beside.
            for name in ('gamma', 'alpha', 'beta'):
                mouse(0, row_of(name), b'M', col=2)
                mouse(0, row_of(name), b'm', col=2)
            until(lambda: all(l[1:].startswith('▶ ') for l in display.lines() if l[1:3] in ('▼ ', '▶ ')))
            mouse(35, ROWS - 1, b'M', col=COLS - 2)  # the pointer off the list

            def bar(name):
                r = row_of(name) - 1
                return display.grid[r][0], display.colour(r, 0) if display.grid[r][0] != ' ' else None
            # gamma is the display's session, so its folded name keeps the
            # bright bar; j j puts the cursor on alpha, which shows the dim one.
            os.write(fd, b'jj')
            if not until(lambda: bar('alpha') == ('▐', HOVER) and bar('gamma') == ('▐', SELECTED)
                         and bar('beta') == (' ', None)):
                failures.append('the cursor on a folded session did not show: %r'
                                % [bar(n) for n in ('gamma', 'alpha', 'beta')])
            os.write(fd, b'\r')
            if not until(lambda: on() == 'alpha' and bar('alpha') == ('▐', SELECTED)):
                failures.append('Enter on a folded session did not switch to it: %r' % on())
        finally:
            for child in (pid, cpid):
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.kill(child, sig)
                    except ProcessLookupError:
                        break
                    time.sleep(0.1)
                try:
                    os.waitpid(child, os.WNOHANG)
                except ChildProcessError:
                    pass
            os.close(fd)
            os.close(cfd)
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: the digits follow the listed order and ? shows the keys')


if __name__ == '__main__':
    main()
