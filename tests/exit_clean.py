#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Quitting frees what the control worker queued, even if nobody read it.

`controlWorker` fills two queues on `Shared` from the moment it attaches --
notification lines, and the ids of panes that emitted output -- and only the
collector's next pass empties them. Quitting before that pass ran leaked
every queued line and pane id along with the list holding them. `tmm` then
`q` does it on any server with output in it, and a server switch takes the
same teardown, so there it leaked once per switch rather than once per run.

The condition is panes that are actually writing. An earlier version of this
harness used idle shells, saw nothing across nine configurations, and would
have certified the bug fixed; what made it visible was a pane in a loop. So
the sessions here are noisy on purpose, and the test also runs the quit early
enough that the collector cannot have drained them.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import collections
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import keys  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
ROWS, COLS = 40, 170


def answer(fd, data):
    """Reply to what vaxis asks, including the DSR it exits on."""
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        os.write(fd, b'\x1b[?0u')


def main():
    if not BINARY.exists():
        raise SystemExit('build tmm first: zig build')
    root = tempfile.mkdtemp(prefix='tmm-exit-clean-', dir='/tmp')
    conf = os.path.join(root, 'tmux.conf')
    Path(conf).write_text('set -g allow-passthrough on\n')
    env = dict(os.environ, TMUX_TMPDIR=root)
    subprocess.run(['tmux', '-L', 'noisy', '-f', conf, 'new-session', '-d', '-s', 'work',
                    'while :; do date; sleep 0.2; done'],
                   capture_output=True, timeout=10, env=env)
    for _ in range(2):
        subprocess.run(['tmux', '-L', 'noisy', 'split-window', '-t', 'work',
                        'while :; do echo chatter; sleep 0.3; done'],
                       capture_output=True, timeout=10, env=env)
    time.sleep(1.0)
    try:
        failures = []
        for label, extra, delay in (('sidebar only', [], 1.0),
                                    ('with a region', ['--shell', '--split', '30'], 2.0)):
            count, sites = run(root, extra, delay)
            if count:
                failures.append('%s: %d leak report(s) at %s'
                                % (label, count, ', '.join(sorted(sites))))
    finally:
        subprocess.run(['tmux', '-L', 'noisy', 'kill-server'], capture_output=True, env=env)
    if failures:
        raise SystemExit('tmm leaked at exit:\n  ' + '\n  '.join(failures))
    print('ok: tmm exits without leaking the queues the control worker filled, '
          'with the sidebar alone and with a region')


def run(root, extra, delay):
    pid, fd = pty.fork()
    if pid == 0:
        for stale in ('TMUX', 'TMUX_PANE'):
            os.environ.pop(stale, None)
        os.environ.update({'TERM': 'xterm-256color', 'COLORTERM': 'truecolor',
                           'TMUX_TMPDIR': root, 'SHELL': '/bin/sh'})
        try:
            os.execv(str(BINARY), [str(BINARY), '-L', 'noisy'] + extra)
        except Exception:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', ROWS, COLS, COLS * 10, ROWS * 20))
    out, asked, start = bytearray(), False, time.monotonic()
    while time.monotonic() - start < delay + 15:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                data = os.read(fd, 1 << 18)
            except OSError:
                break
            if not data:
                break
            out.extend(data)
            answer(fd, data)
        # Early on purpose: the leak is what the collector has not consumed,
        # so a late quit finds the queues already empty and proves nothing.
        if not asked and time.monotonic() - start > delay:
            # With a region the shell holds the keyboard at startup, so q
            # would go to the shell: the focus key first, then quit from
            # the sidebar.
            if extra:
                os.write(fd, keys.FOCUS)
                time.sleep(0.3)
            os.write(fd, b'q')
            asked = True
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    blob = bytes(out)
    sites = collections.Counter(m.decode() for m in re.findall(rb'src/[^:]*\.zig:\d+', blob))
    return blob.count(b'leaked:'), set(sites)


if __name__ == '__main__':
    main()
