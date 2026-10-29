#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""tmm does not change which session a plain `tmux attach` picks.

tmm's control clients have to attach to some session, and tmux counts them
like any terminal: a plain attach passes over a session one is on, and
attaching marks the session as just used, so after tmm exits a plain attach
goes there instead. Left to tmux, tmm took the very session the person used
last.

Against a disposable server with sessions a, b and c, where b was used last,
a plain attach must land on b:

- tmm started first, then the attach, the way a layout script starts them;
- the attach first, then tmm;
- and in each order again after both are stopped and restarted without
  anything typed in between, which is when tmm's own attach would otherwise
  have been the most recent thing to happen to a session.

The terminal tmm marks as used again must keep its previous session, so
`switch-client -l` still goes where it did.

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
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def spawn(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ.pop('TMUX', None)
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
    return pid, fd


def answer(fd, stop):
    """Read tmm's output and answer its terminal queries, so it starts."""
    while not stop.is_set():
        if not select.select([fd], [], [], 0.05)[0]:
            continue
        try:
            data = os.read(fd, 1 << 16)
        except OSError:
            return
        if b'\x1b[c' in data or b'\x1b[0c' in data:
            os.write(fd, b'\x1b[?1;2c')
        if b'\x1b[5n' in data:
            os.write(fd, b'\x1b[0n')


def stop(child):
    pid, fd = child[:2]
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    if len(child) > 2:
        child[2].set()
    os.close(fd)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-quiet-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        def clients(control):
            return [l.split(' ', 1)[1] for l in
                    tmux('list-clients', '-F', '#{client_control_mode} #{session_name}').splitlines()
                    if l.startswith('1 ' if control else '0 ')]

        def until(predicate, limit=10):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                if predicate():
                    return True
                time.sleep(0.05)
            return False

        def start_tmm():
            child = spawn([str(BINARY), '-S', socket])
            done = threading.Event()
            threading.Thread(target=answer, args=(child[1], done), daemon=True).start()
            if not until(lambda: len(clients(True)) == 2):
                failures.append('tmm never attached both its control clients')
            return child + (done,)

        def attach():
            child = spawn([TMUX, '-S', socket, 'attach'])
            until(lambda: len(clients(False)) == 1)
            return child

        def landed():
            on = clients(False)
            return on[0] if on else None

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'a', '-x', '80', '-y', '24')
        for name in ('b', 'c'):
            time.sleep(1.1)
            tmux('new-session', '-d', '-s', name, '-x', '80', '-y', '24')
        # The person was in c, went to b, and left.
        time.sleep(1.1)
        child = spawn([TMUX, '-S', socket, 'attach', '-t', 'c'])
        until(lambda: clients(False) == ['c'])
        tmux('switch-client', '-t', 'b')
        until(lambda: clients(False) == ['b'])
        stop(child)

        try:
            for order in ('tmm first', 'attach first'):
                for run in ('start', 'restart'):
                    if order == 'tmm first':
                        sidebar = start_tmm()
                        terminal = attach()
                    else:
                        terminal = attach()
                        sidebar = start_tmm()
                    time.sleep(0.3)
                    if landed() != 'b':
                        failures.append('%s, %s: the attach landed on %r, not b (tmm on %r)'
                                        % (order, run, landed(), clients(True)))
                    if 'b' in clients(True):
                        failures.append('%s, %s: tmm attached to b, the session last used'
                                        % (order, run))
                    if order == 'attach first' and run == 'start':
                        name = tmux('list-clients', '-F', '#{?client_control_mode,,#{client_name}}').split()[0]
                        tmux('switch-client', '-c', name, '-t', 'c')
                        tmux('switch-client', '-c', name, '-t', 'b')
                        stop(sidebar)
                        sidebar = start_tmm()
                        last = tmux('display-message', '-c', name, '-p', '#{client_last_session}').strip()
                        if last != 'c':
                            failures.append('marking the terminal as used again changed '
                                            'its previous session to %r' % last)
                    stop(terminal)
                    stop(sidebar)
                    until(lambda: not clients(True) and not clients(False))
        finally:
            subprocess.run([TMUX, '-S', socket, 'kill-server'], capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: a plain tmux attach lands on the session last used, whichever of it '
          'and tmm starts first, and across restarts')


if __name__ == '__main__':
    main()
