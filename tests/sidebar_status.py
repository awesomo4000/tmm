#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A pane reports its state and the sidebar shows it, no screen reading.

Nothing emits OSC 7501 yet -- the agents would each need a hook at their
event callbacks -- so the emitter here is a `printf`. That is the whole
integration surface a program needs, which is the point: one escape sequence
and the indicator is reported rather than guessed.

What this proves end to end: the sequence leaves a pane process, crosses tmux
as `%output`, is parsed by that pane's terminal inside tmm, rolls up to one
state, and reaches the sidebar row for that pane. The assertions are on what
the sidebar draws, because that is the part a user sees.

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

ROWS, COLS, SPLIT = 44, 170, 34
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-sbstatus-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        # A shell, so the pane has something that can write to its own
        # stdout: the sequence is output from the program, not input to it.
        # Sending it with `send-keys -H` goes to stdin, where `sleep` ignores
        # it and nothing is ever emitted -- which is how the first version of
        # this test failed.
        emitter = os.path.join(root, 'report.sh')
        Path(emitter).write_text("#!/bin/sh\nprintf '\\033]7501;%s\\033\\\\' \"$1\"\n")
        os.chmod(emitter, 0o755)
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24')
        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                    '--session', 'alpha', '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        display = Screen(ROWS, COLS)

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
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

        def sidebar():
            return [line[:SPLIT] for line in display.lines()]

        def until(predicate, limit=12):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def report(pane, body):
            """Run the one-line emitter in the pane, as a program would."""
            tmux('send-keys', '-t', pane, "sh %s '%s'" % (emitter, body), 'Enter')

        try:
            pump(3.0)
            pane = tmux('display-message', '-p', '-t', 'alpha', '#{pane_id}').strip()
            assert pane, 'no pane to report from'

            # Working, with progress: the row shows the percentage.
            report(pane, 'state=working:progress=40')
            assert until(lambda: any('●' in l and '40%' in l for l in sidebar())), \
                ('a working report with progress did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # Blocked on a permission: the kind is what a user needs to see.
            report(pane, 'state=blocked:kind=permission')
            assert until(lambda: any('!' in l and 'permission' in l for l in sidebar())), \
                ('a blocked report did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # Error has no screen-detectable equivalent at all.
            report(pane, 'state=error')
            assert until(lambda: any('✗' in l for l in sidebar())), \
                ('an error report did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # And clearing removes it, falling back to the ordinary row.
            report(pane, 'state=clear')
            assert until(lambda: not any('✗' in l for l in sidebar())), \
                ('a cleared report still showed in the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])
            print('ok: working with progress, blocked with kind, error and '
                  'clear all reached the sidebar from a printf in a pane')
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
