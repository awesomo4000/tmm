#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Quitting compositor mode frees the control stream exactly once.

Shutdown has an ordering requirement: the pane worker blocks in `Stream.next`,
so the child has to be ended before the worker can be joined, and the stream
cannot be freed until after it is. Doing both with one `close` -- which kills
the child and then frees the Stream -- left `Compositor.destroy` to free it a
second time, and the first thing that second pass touches is `pending.items`
in freed memory. Every `--panes` exit aborted on the 0xaa poison pattern.

So `shutdown` ends the child and `close` frees, and this asserts what a user
sees: tmm exits 0 on `q`, with no signal and no leak report. A crash here also
leaves the real terminal in the alternate screen with mouse reporting on,
which is why it is worth a test rather than a note.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
ROWS, COLS = 40, 170


def answer(fd, data):
    """Reply to the queries vaxis makes, including the one it exits on.

    vaxis ends with a DSR and waits for the reply before tearing the terminal
    down. A harness that stops answering sees a hang and would call this test
    failed for the wrong reason.
    """
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        os.write(fd, b'\x1b[?0u')
    for m in re.finditer(rb'\x1b_G([^\x1b]*?)a=q([^\x1b]*?)(?:\x1b\\|$)', data):
        found = re.search(rb'i=(\d+)', m.group(1) + m.group(2))
        os.write(fd, b'\x1b_Gi=%s;OK\x1b\\' % (found.group(1) if found else b'1'))


def main():
    if not BINARY.exists():
        raise SystemExit('build tmm first: zig build')
    root = tempfile.mkdtemp(prefix='tmm-panes-exit-', dir='/tmp')
    sock = os.path.join(root, 'cm')
    conf = os.path.join(root, 'tmux.conf')
    Path(conf).write_text('set -g allow-passthrough on\n')
    subprocess.run(['tmux', '-S', sock, '-f', conf, 'new-session', '-d', '-s', 'c'],
                   capture_output=True, timeout=10)
    try:
        code, sig, out = run(sock)
    finally:
        subprocess.run(['tmux', '-S', sock, 'kill-server'], capture_output=True)

    if sig:
        raise SystemExit('tmm died on %s during shutdown:\n%s'
                         % (signal.Signals(sig).name, tail(out)))
    if code != 0:
        raise SystemExit('tmm exited %d, expected 0:\n%s' % (code, tail(out)))
    if b'leaked' in out:
        raise SystemExit('the allocator reported a leak at exit:\n%s' % tail(out))
    # A clean exit has to put the terminal back as well as not crash.
    if b'\x1b[?1049l' not in out:
        raise SystemExit('tmm exited without leaving the alternate screen')
    print('ok: compositor mode exits 0, frees its control stream once, '
          'and leaves the alternate screen')


def tail(out):
    return out[-600:].decode('utf-8', 'replace')


def run(sock):
    pid, fd = pty.fork()
    if pid == 0:
        for stale in ('TMUX', 'TMUX_PANE'):
            os.environ.pop(stale, None)
        os.environ['TERM'] = 'xterm-256color'
        os.environ['COLORTERM'] = 'truecolor'
        try:
            os.execv(str(BINARY), [str(BINARY), '-S', sock, '--panes',
                                   '--session', 'c', '--split', '30'])
        except Exception:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', ROWS, COLS, COLS * 10, ROWS * 20))
    out, asked, start = bytearray(), False, time.monotonic()
    while time.monotonic() - start < 25:
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
        # Let it attach and draw before quitting: an exit that races the
        # attach would not exercise the teardown this is here for.
        if not asked and time.monotonic() - start > 3:
            os.write(fd, b'q')
            asked = True
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        return 0, 0, bytes(out)
    os.close(fd)
    sig = os.WTERMSIG(status) if os.WIFSIGNALED(status) else 0
    code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
    return code, sig, bytes(out)


if __name__ == '__main__':
    main()
