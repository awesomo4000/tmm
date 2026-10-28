#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""tmm started before its tmux server picks the server up once it starts.

tmm opens on a socket nothing is listening on, and says so. Then a server
starts with a session and a display attaches: the session and the display
must appear, and the display, as the only one, be selected. Before the fix
the collector gave up after its first failed pass, and the long-lived query
client, opened while there was no server, stayed dead, so nothing that
started afterwards was ever shown.

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


def spawn(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ.pop('TMUX', None)
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    return pid, fd


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-late-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')
        pid, fd = spawn([str(BINARY), '-S', socket])
        client = None
        display = Screen(ROWS, COLS)

        def pump(duration):
            until_ = time.monotonic() + duration
            while time.monotonic() < until_:
                fds = [fd] + ([client[1]] if client else [])
                for ready in select.select(fds, [], [], 0.02)[0]:
                    try:
                        data = os.read(ready, 1 << 16)
                    except OSError:
                        continue
                    if ready != fd:
                        continue
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

        def shows(text):
            return any(text in line for line in display.lines())

        try:
            if not until(lambda: shows('no server running')):
                failures.append('tmm did not say there was no server: %r' % display.lines())
            subprocess.run([TMUX, '-S', socket, '-f', '/dev/null', 'new-session', '-d',
                            '-s', 'late', '-x', '80', '-y', '24'], capture_output=True, timeout=5)
            client = spawn([TMUX, '-S', socket, 'attach', '-t', 'late'])
            if not until(lambda: shows('▼ 1 late')):
                failures.append('the session on the late server never appeared: %r'
                                % display.lines())
            if not until(lambda: any(l[1:].startswith('➤ ') and ': late' in l for l in display.lines())):
                failures.append('the display on the late server was not shown and selected: %r'
                                % display.lines())
            if shows('no server running'):
                failures.append('the no-server message stayed after the server started')
        finally:
            for child in (pid, client[0] if client else None):
                if child is None:
                    continue
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
            if client:
                os.close(client[1])
            subprocess.run([TMUX, '-S', socket, 'kill-server'], capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: a server started after tmm is picked up, with its session and display')


if __name__ == '__main__':
    main()
