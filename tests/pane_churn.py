#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Type and click into panes while they are being created and destroyed.

The compositor's event worker frees a pane that leaves the layout, while the
display thread looks a pane up to give it a keystroke, a mouse event, a blit
or the cursor. Those lookups used to return the pointer and then release the
lock, so a `kill-pane` arriving in between left the display reading freed
memory. This drives that window: keys and clicks continuously, panes
appearing and disappearing underneath them.

This one is the broad guard: keys, clicks, blits and cursor lookups all
competing with panes appearing and being destroyed. It does not demonstrate
the use-after-free -- it passes against the buggy build, because freed memory
stays mapped and poisoned so a stale read yields nonsense rather than a
fault. tests/pane_use_after_free.py proves that one directly, with a
sentinel. What this guards is the fix: holding a lock for longer risks a
deadlock and risks starving the event worker, and churn is what would show
either.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
from pathlib import Path
import pty
import random
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROWS, COLS, SPLIT = 40, 160, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
ROUNDS = 30


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    random.seed(7)
    with tempfile.TemporaryDirectory(prefix='tmm-churn-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24', 'sleep 600')

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                    '--session', 'alpha', '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        seen = bytearray()

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.01)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    seen.extend(data)
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        pump(2.0)
        os.write(fd, b'\x1b[24~')      # F12: focus the region
        pump(0.4)

        try:
            for i in range(ROUNDS):
                # Split, so panes appear; keys and clicks land throughout.
                panes = tmux('list-panes', '-t', 'alpha', '-F', '#{pane_id}').split()
                if panes and len(panes) < 6:
                    tmux('split-window', '-d', '-t', panes[-1], 'sleep 600')
                for _ in range(8):
                    os.write(fd, b'x')
                    col = random.randint(SPLIT + 2, COLS - 2)
                    row = random.randint(1, ROWS - 2)
                    os.write(fd, ('\x1b[<0;%d;%dM' % (col, row)).encode())
                    os.write(fd, ('\x1b[<0;%d;%dm' % (col, row)).encode())
                pump(0.05)
                # And kill one, so the worker frees a pane under the display.
                panes = tmux('list-panes', '-t', 'alpha', '-F', '#{pane_id}').split()
                if len(panes) > 1:
                    tmux('kill-pane', '-t', random.choice(panes))
                for _ in range(8):
                    os.write(fd, b'y')
                pump(0.05)

            # Still alive, and still drawing: a crash would have closed the pty.
            pump(1.0)
            before = len(seen)
            os.write(fd, b'z')
            pump(0.8)
            assert os.waitpid(pid, os.WNOHANG) == (0, 0), \
                'tmm exited during pane churn (use-after-free would do this)'
            assert len(seen) > before, 'tmm stopped drawing during pane churn'
            print('ok: %d rounds of keys and clicks against panes appearing and '
                  'going; tmm alive and drawing' % ROUNDS)
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
