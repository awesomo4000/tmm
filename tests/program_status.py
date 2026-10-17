#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A program in the region reports what it is doing, and tmm answers it.

OSC 7501 program status, revision 0.4. Two halves, and the first is what a
program depends on: it sends `OSC 7501 ; ?` and a terminal that supports the
protocol replies, listing the states and kinds it accepts. A program that
gets no reply is specified to treat the protocol as unsupported, which is
what tmm said until the effect hook was set.

The reply has to cross two boundaries to get back: tmm's terminal produces it
through its write-pty effect, which lands in the region's sink and goes to
the program's stdin. In compositor mode that same path is a `send-keys -H`
into the pane. Here it is the pty, which is the simpler of the two.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
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

ROWS, COLS, SPLIT = 40, 160, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-status-', dir='/tmp') as root:
        replies = os.path.join(root, 'replies')
        status_log = os.path.join(root, 'status.log')
        child = os.path.join(root, 'child.py')
        # Python rather than a shell script: the reply has no newline and is
        # shorter than any fixed count, so `head -c N` blocks forever and
        # `cat` buffers what it read into oblivion when killed. Here the read
        # is a select with a deadline.
        Path(child).write_text(
            'import os, select, sys, termios, time, tty\n'
            # Raw mode, or the line discipline holds the reply: it carries no
            # newline, and a canonical-mode read only returns on one.
            'tty.setraw(0)\n'
            'os.write(1, b"\\033]7501;?\\033\\\\")\n'
            'got = b""\n'
            'end = time.monotonic() + 3\n'
            'while time.monotonic() < end:\n'
            '    if select.select([0], [], [], 0.05)[0]:\n'
            '        got += os.read(0, 256)\n'
            'open(%r, "wb").write(got)\n'
            'os.write(1, b"\\033]7501;state=working:id=build:progress=40:app=zig\\033\\\\")\n'
            'time.sleep(0.5)\n'
            'os.write(1, b"\\033]7501;state=blocked:id=build/link:kind=permission\\033\\\\")\n'
            'time.sleep(300)\n' % replies)
        runner = os.path.join(root, 'run.sh')
        Path(runner).write_text('#!/bin/sh\nexec %s %s\n' % (sys.executable, child))
        os.chmod(runner, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run([TMUX, '-S', socket, 'new-session', '-d', '-s', 's'],
                       capture_output=True, timeout=10)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ.pop('TMUX', None)
            os.environ['SHELL'] = runner
            os.environ['TMM_INPUT_LOG'] = status_log
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                    '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    if b'\x1b[c' in data:
                        os.write(fd, b'\x1b[?62;c')

        try:
            pump(6.0)
            reply = Path(replies).read_bytes() if os.path.exists(replies) else b''
            assert b'7501' in reply, \
                ('tmm did not answer the support query, so a program is '
                 'specified to treat the protocol as unsupported', reply[:80])
            # Revision 0.4: the reply is its own form, listing what the
            # terminal accepts, rather than an echo of the query.
            assert b'states=' in reply, \
                ('the reply carried no state list', reply[:80])
            states = re.search(rb'states=([a-z,]+)', reply)
            assert states and b'blocked' in states.group(1), \
                ('the terminal did not advertise the blocked state', reply[:80])
            # And the reports themselves are captured, with the hierarchy
            # intact: a child record addressed by a path under its parent.
            log = Path(status_log).read_text() if os.path.exists(status_log) else ''
            lines = [l for l in log.splitlines() if l.startswith('status ')]
            assert any('id="build"' in l and 'state=working' in l and
                       'progress=40' in l and 'app=zig' in l for l in lines), \
                ('the working report was not captured', lines[-5:])
            assert any('id="build/link"' in l and 'state=blocked' in l and
                       'kind=permission' in l for l in lines), \
                ('the blocked child report was not captured', lines[-5:])
            print('ok: support query answered with %r; %d report(s) captured '
                  'including the child record'
                  % (states.group(1).decode()[:40], len(lines)))
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
