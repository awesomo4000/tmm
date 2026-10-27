#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Bars in the gutter mark sessions, wider at the row itself: a bright one
stays with the selected session, which also sits on a faint card fading to
the right, and a dim
one follows the pointer and goes when the pane loses focus. A lone display
is selected without being asked for, marked `➤` and ending in the blink mark.

Two tmm runs against one disposable server:

- The first starts with no display attached. When one attaches it is the only
  choice, so it is selected: the blink mark, which only shows on a selected
  display, appears.
- The second starts with that display already attached and selects it at once.
  Its row carries `➤` and no bar. Its session has the bright bar, wide at its
  current pane, and the card behind it through the blank row that closes
  it. Then the pointer
  hovers a pane of another session: the dim bar runs from that session's name
  through the blank row below it, wide at the pane, with no card, and the
  selected session keeps its bright one. A focus-out report (what a terminal
  sends when the pane loses focus) must take the dim bar away.

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
BAR, WIDE = '▎', '◗'
BRIGHT, DIM = ('rgb', 72, 214, 176), ('rgb', 58, 96, 90)
CARD = ('rgb', 40, 46, 53)


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

    def gutter(self, text, above=0):
        """What the gutter holds left of the row starting `text`, or `above`
        rows over it."""
        r = self.row_of(text)
        return 'not drawn' if r is None else self.display.grid[r - above][0]

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
        tmux('new-session', '-d', '-s', 'gamma', '-x', '80', '-y', '24')
        client = None
        uis = []
        try:
            first = Ui(socket)
            uis.append(first)
            if not first.until(lambda: first.shows('no attached displays')):
                failures.append('the first run never drew its empty display list')
            if first.shows('✶'):
                failures.append('a display was selected before any attached')
            client = spawn([TMUX, '-S', socket, 'attach', '-t', 'alpha'], 24, 80)
            if not first.until(lambda: first.shows('✶')):
                failures.append('the first display to attach was not selected: %r'
                                % first.display.lines())
            stop(first.pid, first.fd)
            uis.remove(first)

            second = Ui(socket)
            uis.append(second)
            if not second.until(lambda: second.shows('✶')):
                failures.append('the one attached display was not selected at launch: %r'
                                % second.display.lines())
            if not second.until(lambda: any(l[1:].startswith('➤ ') and l.endswith(' : alpha ✶')
                                            for l in second.display.lines())):
                failures.append('the selected display was not marked: %r'
                                % second.display.lines())
            # The selected session sits on a faint card the height of its
            # bar, through the blank row after it, fading out to the right.
            def carded(r):
                left = second.display.background(r, 0)
                middle = second.display.background(r, COLS // 2)
                # Faded out completely some columns short of the edge.
                tail = [second.display.background(r, c) for c in range(COLS - 6, COLS)]
                return (left == CARD and middle not in (None, CARD)
                        and sum(middle[1:]) < sum(CARD[1:]) and tail == [None] * 6)
            alpha_row = second.row_of('▼ alpha')
            if alpha_row is None or not second.until(lambda: all(carded(alpha_row + d) for d in (0, 1, 2))):
                failures.append('the selected session was not on its fading card: %r'
                                % ([(second.display.background(alpha_row + d, 0),
                                     second.display.background(alpha_row + d, COLS // 2),
                                     second.display.background(alpha_row + d, COLS - 1)) for d in (0, 1, 2)]
                                   if alpha_row is not None else None,))
            elif second.display.background(alpha_row + 3, 0) is not None:
                failures.append('the card ran into the next session')
            display = second.row_of('➤ ')
            if display is None or second.display.colour(display, 1) != BRIGHT \
                    or second.display.grid[display][0] != ' ':
                failures.append('the selected display should have a bright arrow and no bar: %r'
                                % (second.display.lines()[display] if display is not None else None,))

            def bars(top, count):
                """The gutter from row `top` down, as (glyph, colour) pairs."""
                return [(second.display.grid[r][0],
                         second.display.colour(r, 0) if second.display.grid[r][0] != ' ' else None)
                        for r in range(top, top + count)]

            alpha = second.row_of('▼ alpha')
            selected = [(BAR, BRIGHT), (WIDE, BRIGHT), (BAR, BRIGHT)]
            if alpha is None or not second.until(lambda: bars(alpha, 3) == selected):
                failures.append('the selected session did not keep the bright bar: %r'
                                % (bars(alpha, 3) if alpha is not None else None,))
            row = second.row_of('▼ beta')
            if row is None:
                failures.append('the beta session never drew')
            else:
                # The pane under beta's name.
                os.write(second.fd, b'\x1b[<35;6;%dM' % (row + 2))
                # The blank row above beta closes alpha's group, so it is
                # alpha's bright bar, not the hover's.
                hovered = [(BAR, BRIGHT), (BAR, DIM), (WIDE, DIM), (BAR, DIM)]
                if not second.until(lambda: bars(row - 1, 4) == hovered):
                    failures.append('hover did not run the dim bar from the session through '
                                    'the blank row below it: %r' % bars(row - 1, 4))
                if second.fill('▼ beta') is not None:
                    failures.append('hover recoloured the line: %r'
                                    % (second.fill('▼ beta'),))
                if bars(alpha, 3) != selected:
                    failures.append('hovering elsewhere changed the selected bar: %r'
                                    % bars(alpha, 3))
                os.write(second.fd, b'\x1b[O')
                if not second.until(lambda: bars(row, 3) == [(' ', None)] * 3):
                    failures.append('losing focus did not clear the hover: %r' % bars(row, 3))
                if bars(alpha, 3) != selected:
                    failures.append('losing focus cleared the selected bar: %r' % bars(alpha, 3))
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
