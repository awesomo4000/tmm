#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The machine's own floor: a byte written to a pty, read by the process on
the other end. Nothing of tmm or tmux is involved.

This is what a keystroke costs when nothing is in the way -- a write, a
wakeup, and a read -- so it is the number every other latency here sits on
top of. Subtracting it is how tmm's share of a worst case is told apart from
the scheduler's. Run it when a figure elsewhere looks surprising: a spike
that shows up here too was never tmm's.

Both ends read CLOCK_MONOTONIC_RAW, and the far end is keyprobe, whose own
cost is 19ns.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keylag import PROBE, arrivals, clock_ns  # noqa: E402

# Lower case and digits only: the probe stops on `Q`, and an alphabet
# containing its own stop byte ends the run halfway through.
KEYS = 'abcdefghijklmnopqrstuvwxyz0123456789'
N = len(KEYS)
ROWS, COLS = 40, 160


def run(load, gap=0.05):
    with tempfile.TemporaryDirectory(prefix='pty-floor-', dir='/tmp') as root:
        log = os.path.join(root, 'probe.log')
        argv = [str(PROBE), '--log', log] + (['--load'] if load else [])
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp(argv[0], argv)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
        time.sleep(0.6)

        keys = KEYS
        sent = {}
        for key in keys:
            # Drain the blast so the pty never backs up into our own write.
            if load:
                ready, _, _ = select.select([fd], [], [], 0)
                for f in ready:
                    try:
                        os.read(f, 1 << 16)
                    except OSError:
                        pass
            sent[key] = clock_ns()
            os.write(fd, key.encode())
            end = time.monotonic() + gap
            while time.monotonic() < end:
                ready, _, _ = select.select([fd], [], [], 0.005)
                for f in ready:
                    try:
                        os.read(f, 1 << 16)
                    except OSError:
                        pass
        os.write(fd, b'Q')
        end = time.monotonic() + 1.0
        while time.monotonic() < end:
            ready, _, _ = select.select([fd], [], [], 0.02)
            for f in ready:
                try:
                    os.read(f, 1 << 16)
                except OSError:
                    pass
        got = arrivals(log)
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        os.close(fd)
        return [((got[k] - sent[k]) / 1e6, i) for i, k in enumerate(keys) if k in got], len(keys)


def main():
    if not PROBE.exists():
        raise SystemExit('build first: zig build')
    print('pty floor: write -> read, nothing in between')
    for load in (False, True):
        lat, n = run(load)
        if not lat:
            print('  %-6s no samples' % ('load' if load else 'quiet'))
            continue
        values = sorted(x for x, _ in lat)
        p99 = values[min(len(values) - 1, int(len(values) * 0.99))]
        print('  %-6s n=%d/%d  min %6.3f  median %6.3f  p99 %7.3f  MAX %7.3f ms  '
              '(worst at %d of %d)'
              % ('load' if load else 'quiet', len(lat), n, values[0],
                 statistics.median(values), p99, values[-1], max(lat)[1], n))
        slow = [(i, round(x, 3)) for x, i in sorted(lat) if x > 1.0]
        if slow:
            print('         over 1ms: %s' % slow)


if __name__ == '__main__':
    main()
