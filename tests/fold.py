#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A folded session hides its panes and still says when one has finished.

Clicking `[-]` folds a session to its name; clicking `[+]` opens it again.
Folded, the name turns green when a pane in it shows a check, because that is
the one thing the hidden rows would have told a person. A session whose agent
is merely blocked does not.

The screen model keeps no colour, so the colour is read from the bytes tmm
wrote for the name.

Only disposable tmux sockets and files under /tmp are mutated.
"""
import fcntl
import os
from pathlib import Path
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402

ROWS, COLS = 40, 60
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
GREEN = b'\x1b[32m'


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
        raw = bytearray()

        def pump(duration):
            until_ = time.monotonic() + duration
            while time.monotonic() < until_:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    display.feed(data)
                    raw.extend(data)
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

        def painted(text):
            """The foreground colour in force where `text` was last written."""
            at = raw.rfind(text)
            colours = re.findall(rb'\x1b\[(?:3[0-79]|9[0-7])m', bytes(raw[:max(at, 0)]))
            return colours[-1] if at >= 0 and colours else b''

        try:
            if not until(lambda: any('[-] finished' in l for l in rows())
                         and sum(l.startswith('  ') for l in rows()) >= 2):
                failures.append('the sessions never drew open: %r' % rows())
            for name in ('finished', 'waiting'):
                click_fold(name)
            if not until(lambda: '[+] finished' in rows() and '[+] waiting' in rows()):
                failures.append('the sessions did not fold: %r' % rows())
            if any('claude' in l for l in rows()):
                failures.append('a folded session still drew its panes: %r' % rows())
            # Repaint both names from scratch, so the bytes below are this
            # frame's and not left over from before the fold.
            raw.clear()
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS - 1, 0, 0))
            os.kill(pid, signal.SIGWINCH)
            until(lambda: b'[+] finished' in raw and b'[+] waiting' in raw, 5)
            if GREEN not in painted(b'[+] finished'):
                failures.append('a folded session with a finished agent was not '
                                'green: %r' % painted(b'[+] finished'))
            if GREEN in painted(b'[+] waiting'):
                failures.append('a folded session with a blocked agent was green: %r' % painted(b'[+] waiting'))

            click_fold('finished')
            if not until(lambda: '[-] finished' in rows()
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
