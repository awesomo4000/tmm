#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A folded session hides its panes and still says when one has finished.

Also checks that the accents take compost's border colours.

Clicking `▼` folds a session to its name; clicking `▶` opens it again.
Folded, the name turns green when a pane in it shows a check, because that is
the one thing the hidden rows would have told a person. A session whose agent
is merely blocked does not.

The colour is read per cell from the screen model, at the name's first
letter.

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
GREEN = ('index', 2)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-fold-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'finished', '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'waiting', '-x', '80', '-y', '24')
        for session, state in (('finished', 'done'), ('waiting', 'blocked')):
            pane = tmux('display-message', '-p', '-t', session, '#{pane_id}').strip()
            tmux('set', '-p', '-t', pane, '@agent_hint', 'claude')
            tmux('set', '-p', '-t', pane, '@agent_state', state)

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

        def rows():
            return [l.rstrip() for l in display.lines() if l.strip()]

        def until(predicate, limit=15):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def click_fold(name):
            row = next(i for i, l in enumerate(display.lines()) if l.endswith(' ' + name) or (' ' + name + ' ') in l + ' ')
            for final in (b'M', b'm'):
                os.write(fd, b'\x1b[<0;2;%d%s' % (row + 1, final))
                pump(0.2)

        def shown(name):
            """A session row, which carries the session's directory after it."""
            return any(l == name or l.startswith(name + ' ') for l in rows())

        def painted(text):
            """The foreground colour of the first letter of the name in a row."""
            for r, line in enumerate(display.lines()):
                if line.strip() == text or line.strip().startswith(text + ' '):
                    return display.colour(r, line.index(text) + len('▶ '))
            return 'not drawn'

        try:
            if not until(lambda: any('▼ finished' in l for l in rows())
                         and sum(l.startswith('  ') for l in rows()) >= 2):
                failures.append('the sessions never drew open: %r' % rows())
            # The title starts at compost's top-left border colour, which is
            # what ties tmm's accents to the frame it sits in.
            if display.colour(0, 0) != ('rgb', 244, 55, 151):
                failures.append('the title did not start at the aurora corner: '
                                '%r' % (display.colour(0, 0),))
            for name in ('finished', 'waiting'):
                click_fold(name)
            if not until(lambda: shown('▶ finished') and shown('▶ waiting')):
                failures.append('the sessions did not fold: %r' % rows())
            if any('claude' in l for l in rows()):
                failures.append('a folded session still drew its panes: %r' % rows())
            if painted('▶ finished') != GREEN:
                failures.append('a folded session with a finished agent was not '
                                'green: %r' % (painted('▶ finished'),))
            # Drawn, and in some other colour: a name that was never found
            # must not pass as "not green".
            waiting = painted('▶ waiting')
            if waiting == GREEN or waiting == 'not drawn':
                failures.append('a folded session with a blocked agent was not '
                                'drawn in its own colour: %r' % (waiting,))

            click_fold('finished')
            if not until(lambda: shown('▼ finished')
                         and any('claude' in l for l in rows())):
                failures.append('the session did not open again: %r' % rows())
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
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: sessions fold and open, and a folded session is green only '
          'when an agent in it has finished')


if __name__ == '__main__':
    main()
