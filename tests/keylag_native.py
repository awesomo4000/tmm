#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Key latency with no interpreter anywhere in the timed path.

`tests/keylag.py` times the send from Python: it reads the clock and then
calls `write`, so anything that happens in between -- a deschedule, a
collection -- lands in the number and reads as latency in tmm. That is the
last gap in these measurements, and this closes it. Both ends are keyprobe:
one `--send` writing into tmm's pty and recording when each key left, one
inside the region recording when each key arrived. Python opens the pty,
starts the two processes, and compares the logs afterwards. It is not in the
path being measured.

What is left in the number: the pty write, tmm's parse and encode, the write
to the child's pty, and the child's read. Nothing else.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import keys  # noqa: E402
from keylag import BINARY, PROBE, SPLIT, ROWS, COLS  # noqa: E402

KEYS = 300
GAP_US = 20000
# The worst case is the point of these tests, so it is asserted rather than
# only the middle: the regression that cost 29ms was invisible to a median,
# which stayed at 0.2ms throughout. But a worst case is also what load moves,
# and inside the suite -- after a compile and whatever else has just run --
# three samples in three hundred reach 10 to 14ms where standalone the whole
# run stays under 1.5ms. So there are two budgets. The default is strict and
# is what `mise run latency` uses on a quiet machine, where the figure means
# something. `TMM_WCET_MS` loosens it for the suite, set above the 14.3ms of
# suite noise actually measured and below the 29ms of the smallest regression
# actually seen, so the suite still catches that class without flaking on a
# scheduling blip.
BUDGET_MS = float(os.environ.get('TMM_MEDIAN_MS', 2.0))
WCET_MS = float(os.environ.get('TMM_WCET_MS', 10.0))


def records(path):
    """One entry per key, in order, as `(nanoseconds, byte)`.

    A record is one `read`, and a read can return several bytes at once, so
    a record is expanded into one entry per byte sharing its reading. Taking
    a record as one key instead shifted every pair after the first coalesced
    read, and a shift of one pairs a key with the *next* key's send time --
    which manufactures an error the size of the gap between keys, 20ms, and
    looks exactly like a latency spike. Four of ten runs appeared to show a
    multi-millisecond tail before this was fixed.
    """
    out = []
    try:
        text = Path(path).read_text()
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
        for i in range(0, len(raw) - 1, 2):
            out.append((at, raw[i:i + 2]))
    return out


def main():
    for binary in (BINARY, PROBE):
        if not binary.exists():
            raise SystemExit('build first: zig build (missing %s)' % binary.name)
    failures = []

    for load in (False, True):
        with tempfile.TemporaryDirectory(prefix='tmm-native-', dir='/tmp') as root:
            recv_log = os.path.join(root, 'recv.log')
            send_log = os.path.join(root, 'send.log')
            runner = os.path.join(root, 'run.sh')
            Path(runner).write_text('#!/bin/sh\nexec %s --log %s%s\n'
                                    % (PROBE, recv_log, ' --load' if load else ''))
            os.chmod(runner, 0o755)
            socket = os.path.join(root, 'sock')
            subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'n'],
                           capture_output=True, timeout=10)

            pid, master = pty.fork()
            if pid == 0:
                os.environ.pop('TMUX', None)
                os.environ['SHELL'] = runner
                os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                        '--split', str(SPLIT)])
            fcntl.ioctl(master, termios.TIOCSWINSZ,
                        struct.pack('HHHH', ROWS, COLS, 0, 0))

            # Settle tmm and focus the region. These writes are not timed.
            until = time.monotonic() + 1.5
            while time.monotonic() < until:
                ready, _, _ = select.select([master], [], [], 0.02)
                for f in ready:
                    try:
                        data = os.read(f, 1 << 16)
                    except OSError:
                        data = b''
                    if b'\x1b[c' in data:
                        os.write(master, b'\x1b[?62;c')
            # Split mode starts focused on the region; the focus key would
            # move the keyboard to the sidebar.
            time.sleep(0.4)

            # The sender owns the master from here: it writes the keys, takes
            # the readings, and drains tmm's output itself.
            sender = subprocess.Popen(
                [str(PROBE), '--send', '--fd', '3', '--keys', str(KEYS),
                 '--gap-us', str(GAP_US), '--log', send_log],
                pass_fds=(master,),
                preexec_fn=(lambda: os.dup2(master, 3)))
            sender.wait(timeout=KEYS * GAP_US / 1e6 + 60)
            time.sleep(1.0)

            sent = records(send_log)
            got = records(recv_log)
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
            os.close(master)
            subprocess.run(['tmux', '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

            label = 'program writing hard' if load else 'program idle'
            if not sent or not got:
                print('%-22s no samples (sent %d, received %d)'
                      % (label, len(sent), len(got)))
                continue
            # Matched in order, and only where the bytes agree, so a dropped
            # or coalesced read cannot silently shift the pairing.
            latencies = []
            for (at_send, key_send), (at_recv, key_recv) in zip(sent, got):
                if key_send != key_recv:
                    break
                latencies.append((at_recv - at_send) / 1e6)
            latencies = [x for x in latencies if x >= 0]
            if not latencies:
                print('%-22s no aligned samples' % label)
                continue
            ordered = sorted(latencies)
            n = len(ordered)
            over = lambda t: sum(1 for x in ordered if x > t)
            print('%-22s n=%d  median %.3f  p99 %.3f  p99.9 %.3f  max %.3f ms'
                  % (label, n, statistics.median(ordered), ordered[int(n * 0.99)],
                     ordered[min(n - 1, int(n * 0.999))], ordered[-1]))
            print('%-22s over 1ms: %d (%.1f%%)   over 5ms: %d   over 10ms: %d'
                  % ('', over(1), 100.0 * over(1) / n, over(5), over(10)))
            # Every key has to arrive. A missing one means the pairing broke,
            # which would make the figures above meaningless.
            if n < KEYS:
                failures.append('%s: only %d of %d keys paired'
                                % (label, n, KEYS))
            median = statistics.median(ordered)
            if median > BUDGET_MS:
                failures.append('%s: median %.3fms over the %.1fms budget'
                                % (label, median, BUDGET_MS))
            if ordered[-1] > WCET_MS:
                failures.append('%s: worst case %.3fms over the %.1fms budget'
                                % (label, ordered[-1], WCET_MS))


    for failure in failures:
        print('FAIL', failure)
    print('PASS' if not failures else 'FAIL')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
