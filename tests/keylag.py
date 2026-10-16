#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Measures how long a keypress takes to reach the program inside tmm.

Both ends read the same clock, `CLOCK_MONOTONIC_RAW`, and the far end is
`keyprobe` (src/keyprobe.zig) rather than a Python script: the harness takes
a reading immediately before writing the key byte, and the probe takes one
on the line after its own `read` returns it. The difference is delivery
latency with nothing of either program in it.

The probe exists because this harness used to be Python on both ends, which
put the noise floor -- one to five milliseconds of interpreter and scheduler
jitter -- above the thing being measured, a tenth of a millisecond. An
instrument has to be quicker than its subject or a worst case cannot be told
from a hiccup in the instrument. `keyprobe --overhead` reports what a
reading costs (19ns mean, 125ns worst here) and `--clock` is how the two
clocks are checked to be the same source rather than assumed to be.

Each mode is measured quiet and with the far end writing continuously the
way a redrawing program does, because only the loaded case ever regressed.
`--shell` writes to a pty tmm owns; `--panes` goes out as `send-keys -H`
through tmux, whose own share of that path is measured by tests/tmux_floor.py
and is under a millisecond.

The probe never blocks on its own output and writes its records only at
exit, so a latency reported here is time tmm took and not time the probe
spent in `write`.

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
# A keypress has a deadline and a frame does not, so the budget is on the
# worst case and not only the middle: what a player or a typist notices is
# the jitter. Both are set well above what is measured -- around 0.2ms
# median and under 1ms worst, loaded or quiet -- so this catches a return of
# the coupling (which cost 23ms median and 78ms worst) rather than noise.
BUDGET_MS = 5.0
WCET_MS = 10.0

PROBE = Path(__file__).resolve().parents[1] / 'zig-out/bin/keyprobe'
CLOCK = getattr(time, 'CLOCK_MONOTONIC_RAW', time.CLOCK_MONOTONIC)


def clock_ns():
    """The one clock, read the same way the probe reads it."""
    return time.clock_gettime_ns(CLOCK)


def runner(root, load, log):
    """A tiny script for tmm's SHELL, so the region's child is the probe."""
    path = os.path.join(root, 'run-%d.sh' % load)
    Path(path).write_text('#!/bin/sh\nexec %s --log %s%s\n'
                          % (PROBE, log, ' --load' if load else ''))
    os.chmod(path, 0o755)
    return path


def arrivals(log):
    """Parse the probe's records: one `<nanoseconds> <hex bytes>` per read."""
    out = {}
    try:
        text = Path(log).read_text()
    except FileNotFoundError:
        return out
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            at = int(parts[0])
        except ValueError:
            continue
        raw = parts[1]
        # A single read can carry several keys; each gets that reading.
        for i in range(0, len(raw) - 1, 2):
            try:
                char = bytes([int(raw[i:i + 2], 16)]).decode('latin-1')
            except ValueError:
                continue
            out.setdefault(char, at)
    return out


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


def measure(fd, log, load):
    """Send KEYS distinct keys one at a time, return per-key latency in ms."""
    sent = {}
    keys = 'abcdefghijkl'[:KEYS]
    for key in keys:
        pump(fd, 0.12 if load else 0.05)
        sent[key] = clock_ns()
        os.write(fd, key.encode())
        pump(fd, 0.25)

    # The probe writes its records at exit, so that writing a file between
    # two keystrokes cannot be charged to the next one. Stop it, then read.
    os.write(fd, b'Q')
    pump(fd, 1.0)
    got = arrivals(log)
    missing = [k for k in keys if k not in got]
    if missing:
        raise AssertionError('keys never reached the probe: %r (load=%s)'
                             % (missing, load))
    return [(got[k] - sent[k]) / 1e6 for k in keys]


def report(label, samples):
    """Where the worst sample fell is reported too: the first keystroke being
    the slow one means something settling, and a late one means something
    recurring. Guessing between those cost a wrong answer once already."""
    worst_at = max(range(len(samples)), key=samples.__getitem__)
    ordered = sorted(samples)
    p90 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.9))]
    print('  %-22s min %7.3f  median %7.3f  p90 %7.3f  max %7.3f  ms  '
          '(worst at key %d of %d)'
          % (label, ordered[0], statistics.median(ordered), p90, ordered[-1],
             worst_at, len(samples)))
    return statistics.median(ordered), ordered[-1]


def check(failures, mode, median, worst):
    if median > BUDGET_MS:
        failures.append('%s loaded median %.1fms over the %.1fms budget'
                        % (mode, median, BUDGET_MS))
    if worst > WCET_MS:
        failures.append('%s loaded worst case %.1fms over the %.1fms budget'
                        % (mode, worst, WCET_MS))


def shell_mode(root, load):
    """A key into the region, whose child is the probe on a pty tmm owns."""
    log = os.path.join(root, 'shell-%d.log' % load)
    socket = os.path.join(root, 'sock-shell-%d' % load)
    subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'lag'],
                   capture_output=True, timeout=10)
    pid, fd = spawn([str(BINARY), '-S', socket, '--shell', '--split', str(SPLIT)],
                    {'SHELL': runner(root, load, log)})
    try:
        pump(fd, 1.2)
        os.write(fd, b'\x1b[24~')   # F12: move the keyboard to the region
        pump(fd, 0.3)
        return measure(fd, log, load)
    finally:
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


def panes_mode(root, load):
    """The same measurement through `--panes`, where a key leaves tmm as a
    `send-keys -H` down the pipe of a long-lived `tmux -C attach` rather than
    a write to a pty tmm owns. tmux's own share of that path is measured by
    tests/tmux_floor.py and is under a millisecond, so what shows up here
    beyond that belongs to tmm."""
    log = os.path.join(root, 'panes-%d.log' % load)
    socket = os.path.join(root, 'sock-panes-%d' % load)
    subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'lag',
                    '-x', str(COLS), '-y', str(ROWS),
                    '%s --log %s%s' % (PROBE, log, ' --load' if load else '')],
                   capture_output=True, timeout=10)
    pid, fd = spawn([str(BINARY), '-S', socket, '--panes', '--session', 'lag',
                     '--split', str(SPLIT)], {})
    try:
        pump(fd, 2.0)
        os.write(fd, b'\x1b[24~')   # F12: move the keyboard to the region
        pump(fd, 0.5)
        return measure(fd, log, load)
    finally:
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
    for binary in (BINARY, PROBE):
        if not binary.exists():
            raise SystemExit('build first: zig build (missing %s)' % binary.name)
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-keylag-', dir='/tmp') as root:
        print('--shell: key -> program inside the region')
        quiet = shell_mode(root, load=False)
        report('quiet', quiet)
        loaded = shell_mode(root, load=True)
        median, worst = report('under output load', loaded)
        check(failures, '--shell', median, worst)

        print('--panes: key -> process in a tmux pane')
        report('quiet', panes_mode(root, load=False))
        panes_loaded = panes_mode(root, load=True)
        median, worst = report('under output load', panes_loaded)
        check(failures, '--panes', median, worst)
    for f in failures:
        print('FAIL', f)
    print('PASS' if not failures else 'FAIL')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
