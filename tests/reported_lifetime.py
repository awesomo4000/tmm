#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A reported record outlives its writer only when the specification says so.

The Program Status Protocol ends `working` and `blocked` records when the
program that wrote them exits or the next shell prompt starts, and lets a
terminal end `idle` then too; `done` and `error` survive both. tmm used to
keep whatever `@tmm_status` held until something cleared it, so an agent
killed with `kill -9` -- which sends no clear -- read as working for as long
as the pane existed.

tmm never sees a pane's bytes, so it has no OSC 133 prompt marks. What it has
is the process table, and a pane whose own shell runs nothing is at its
prompt. This kills the reporter the way a crash would, with SIGKILL and no
clear, and asserts the row stops claiming work -- and that a `done` record,
the one a person has not looked at yet, stays.

The record is written straight to the pane option rather than through a hook,
because what is under test is tmm's reading of it, not the hook.

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
from screen import Screen  # noqa: E402

ROWS, COLS = 40, 120
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
# Unusual on purpose, so the process this kills can only be the one it started.
NAP = '31337'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-lifetime-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'work',
             '-x', '80', '-y', '24')
        pane = tmux('display-message', '-p', '-t', 'work', '#{pane_id}').strip()
        shell_pid = tmux('display-message', '-p', '-t', 'work', '#{pane_pid}').strip()
        assert pane and shell_pid, 'no pane to report from'

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

        def nap_pid():
            out = subprocess.run(['pgrep', '-P', shell_pid, '-f', 'sleep ' + NAP],
                                 capture_output=True, text=True).stdout.split()
            return int(out[0]) if out else None

        try:
            pump(3.0)
            # A program running under the pane's shell, which has reported
            # that it is working.
            tmux('send-keys', '-t', pane, 'sleep ' + NAP, 'Enter')
            if not until(lambda: nap_pid() is not None, 5):
                failures.append('the stand-in reporter never started')
            tmux('set', '-p', '-t', pane, '@tmm_status', 'state=working')
            if not until(lambda: any('●' in l for l in rows())):
                failures.append('a working report never showed: %r' % rows()[-10:])

            # Killed the way a crash kills it: SIGKILL, so no clear is sent
            # and the option still says working.
            victim = nap_pid()
            if victim:
                os.kill(victim, signal.SIGKILL)
            stored = tmux('show', '-pv', '-t', pane, '@tmm_status').strip()
            if stored != 'state=working':
                failures.append('the harness expected the option to survive '
                                'the kill, and it read %r' % stored)
            if not until(lambda: not any('●' in l for l in rows())):
                failures.append('the row still claimed work after its writer '
                                'was killed: %r' % rows()[-10:])

            # A finished result outlives the prompt, as the specification
            # says: that is the record a person still has to look at.
            tmux('set', '-p', '-t', pane, '@tmm_status', 'state=done')
            if not until(lambda: any('✓' in l for l in rows())):
                failures.append('a done record at the prompt did not show: %r'
                                % rows()[-10:])
            # And it holds across several refreshes rather than flickering.
            pump(2.0)
            if not any('✓' in l for l in rows()):
                failures.append('the done record vanished at the prompt')
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
    print('ok: a working record ended when its writer was killed without '
          'clearing it, and a done record stayed at the prompt')


if __name__ == '__main__':
    main()
