#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Measures how long a keypress takes to reach the program inside tmm.

The number that matters is the one the program inside experiences, so that
is what is timed: the harness records a monotonic clock reading immediately
before writing the key byte into tmm's pty, and the child records one the
instant `read` returns it. CLOCK_MONOTONIC is shared across processes on
this machine, so the difference is the delivery latency with nothing of the
harness in it.

Each condition is measured twice over: quiet, and with the child writing
continuously the way a redrawing program does. The loaded case is the one
that regressed in practice -- a flood of output and a keypress compete for
the same event queue, and the key is behind the flood.

The child never blocks on its own output (its stdout is nonblocking and
EAGAIN is dropped), so a latency measured here is time tmm took to deliver
the byte, not time the child spent stuck in write.

Only disposable files and tmux sockets under /tmp are mutated.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
ROWS, COLS, SPLIT = 40, 160, 30
KEYS = 12
# A keypress that takes longer than this to cross tmm is the bug this
# measures: it is well beyond anything a person would call immediate.
BUDGET_MS = 50.0

CHILD = r'''
import os, select, sys, time
marker = os.environ['LAG_MARKER']
load = os.environ.get('LAG_LOAD') == '1'
os.set_blocking(1, False)
import termios, tty
try:
    tty.setraw(0)
except Exception:
    pass
# A full screen of output per iteration, like a program repainting itself.
chunk = (('x' * 78) + '\r\n').encode() * 40
log = open(marker, 'ab', buffering=0)
while True:
    r, _, _ = select.select([0], [], [], 0 if load else 0.05)
    if r:
        try:
            data = os.read(0, 64)
        except OSError:
            break
        if not data:
            break
        now = time.monotonic()
        for byte in data:
            log.write(('%r %.6f\n' % (bytes([byte]), now)).encode())
        if b'Q' in data:
            break
    if load:
        try:
            os.write(1, chunk)
        except BlockingIOError:
            pass
        except OSError:
            break
'''


def spawn(argv, env, rows=ROWS, cols=COLS):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop('TMUX', None)
        os.environ.update(env)
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    return pid, fd


def pump(fd, duration):
    """Read tmm's output so it is never blocked on us, and answer DA1."""
    until = time.monotonic() + duration
    while time.monotonic() < until:
        ready, _, _ = select.select([fd], [], [], 0.02)
        for f in ready:
            try:
                data = os.read(f, 65536)
            except OSError:
                return
            if b'\x1b[c' in data:
                os.write(fd, b'\x1b[?62;c')


def measure(fd, marker, load):
    """Send KEYS distinct keys one at a time, return per-key latency in ms."""
    sent = {}
    keys = 'abcdefghijkl'[:KEYS]
    for key in keys:
        pump(fd, 0.12 if load else 0.05)
        sent[key] = time.monotonic()
        os.write(fd, key.encode())
        pump(fd, 0.35)

    def collected():
        found = {}
        for line in Path(marker).read_bytes().decode(errors='replace').splitlines():
            try:
                raw, stamp = line.rsplit(' ', 1)
                found.setdefault(eval(raw).decode(), float(stamp))   # b'a' -> a
            except Exception:
                continue
        return found

    # A key still in flight is the symptom, so wait well past the budget for
    # it rather than reporting it as lost.
    deadline = time.monotonic() + 10.0
    arrived = collected()
    while time.monotonic() < deadline and any(k not in arrived for k in keys):
        pump(fd, 0.25)
        arrived = collected()
    missing = [k for k in keys if k not in arrived]
    if missing:
        raise AssertionError('keys never reached the child: %r (load=%s)' % (missing, load))
    return [(arrived[k] - sent[k]) * 1000.0 for k in keys]


def report(label, samples):
    samples = sorted(samples)
    p90 = samples[min(len(samples) - 1, int(len(samples) * 0.9))]
    print('  %-22s min %6.1f  median %6.1f  p90 %6.1f  max %6.1f  ms'
          % (label, samples[0], statistics.median(samples), p90, samples[-1]))
    return statistics.median(samples), samples[-1]


def shell_mode(root, load):
    marker = os.path.join(root, 'marker-shell-%d' % load)
    open(marker, 'wb').close()
    child = os.path.join(root, 'child.py')
    Path(child).write_text(CHILD)
    runner = os.path.join(root, 'run.sh')
    Path(runner).write_text('#!/bin/sh\nexec %s %s\n' % (sys.executable, child))
    os.chmod(runner, 0o755)
    socket = os.path.join(root, 'sock-shell')
    subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'lag'],
                   capture_output=True, timeout=10)
    pid, fd = spawn([str(BINARY), '-S', socket, '--shell', '--split', str(SPLIT)],
                    {'SHELL': runner, 'LAG_MARKER': marker,
                     'LAG_LOAD': '1' if load else '0'})
    try:
        pump(fd, 1.2)
        os.write(fd, b'\x1b[24~')   # F12: move the keyboard to the region
        pump(fd, 0.3)
        return measure(fd, marker, load)
    finally:
        try:
            os.write(fd, b'Q')
        except OSError:
            pass
        pump(fd, 0.2)
        for sig in (15, 9):
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
        subprocess.run(['tmux', '-S', socket, 'kill-server'],
                       capture_output=True, timeout=10)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-keylag-', dir='/tmp') as root:
        print('--shell: key -> program inside the region')
        quiet = shell_mode(root, load=False)
        report('quiet', quiet)
        loaded = shell_mode(root, load=True)
        median, worst = report('under output load', loaded)
        if median > BUDGET_MS:
            failures.append('loaded median %.1fms over the %.1fms budget' % (median, BUDGET_MS))
    for f in failures:
        print('FAIL', f)
    print('PASS' if not failures else 'FAIL')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
