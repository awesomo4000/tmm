#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Proves the pane use-after-free, and that holding the lock fixes it.

The compositor's event worker frees a pane that leaves the layout. A display
thread that looks a pane up, releases the lock, and then uses the pointer can
therefore be using freed memory. That cannot be shown by waiting for a crash:
freed memory stays mapped and poisoned, so a stale read yields nonsense
rather than a fault, and the window is nanoseconds wide.

So the pane carries a sentinel, cleared just before it is freed, and the use
site checks it. A pointer used past its lifetime reads neither the sentinel
nor anything else meaningful, because the allocator poisons what it reclaims.
`TMM_UNSAFE_PANE_LOOKUP` reinstates the old lookup with a wait wide enough to
observe, and `TMM_UAF_LOG` is where a detection is recorded. One binary, both
patterns, same conditions: the only difference is whether the lock is held
across the use.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
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
import keys  # noqa: E402

ROWS, COLS, SPLIT = 40, 160, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
ROUNDS = 8


def run(unsafe):
    """Type into the focused pane, then kill it while that use is in flight."""
    with tempfile.TemporaryDirectory(prefix='tmm-uaf-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')
        uaf_log = os.path.join(root, 'uaf.log')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24', 'sleep 600')

        env = {'TERM': 'xterm-256color', 'TMM_UAF_LOG': uaf_log}
        if unsafe:
            env['TMM_UNSAFE_PANE_LOOKUP'] = '1'
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.pop('TMUX', None)
            os.environ.update(env)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                    '--session', 'alpha', '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.01)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        try:
            pump(2.0)
            os.write(fd, keys.FOCUS)           # focus the region
            pump(0.4)
            for _ in range(ROUNDS):
                # Make sure there is more than one pane, so killing the
                # focused one is a removal rather than the end of the window.
                panes = tmux('list-panes', '-t', 'alpha', '-F', '#{pane_id}').split()
                while len(panes) < 3:
                    tmux('split-window', '-d', '-t', 'alpha', 'sleep 600')
                    pump(0.35)
                    panes = tmux('list-panes', '-t', 'alpha', '-F', '#{pane_id}').split()
                focused = tmux('display-message', '-p', '-t', 'alpha', '#{pane_id}').strip()
                victim = focused if focused in panes else panes[0]
                try:
                    os.write(fd, b'k')          # the use begins here
                except OSError:
                    break
                tmux('kill-pane', '-t', victim)  # and the free lands inside it
                pump(0.3)
            pump(0.5)
            if not os.path.exists(uaf_log):
                return 0
            return len(Path(uaf_log).read_text().strip().splitlines())
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


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    unsafe = run(unsafe=True)
    safe = run(unsafe=False)
    print('lookup that releases the lock first: %d use-after-free detection(s)' % unsafe)
    print('lock held across the use:            %d use-after-free detection(s)' % safe)
    failures = []
    # The point of the test is the contrast. If the old pattern no longer
    # trips, the scaffolding has stopped working and the clean result below
    # proves nothing -- which is worth failing on.
    if unsafe == 0:
        failures.append('the old pattern did not reproduce: the proof no longer proves anything')
    if safe != 0:
        failures.append('holding the lock did not prevent it: %d detections' % safe)
    for f in failures:
        print('FAIL', f)
    print('PASS' if not failures else 'FAIL')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
