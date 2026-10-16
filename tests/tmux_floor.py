#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""What does tmux alone cost on the send-keys path? tmm is not involved.

A control client writes `send-keys -t %0 -H <hex>` down the pipe of a
long-lived `tmux -C attach`, and the process in the pane records the moment
its own read returns the byte. The difference is tmux waking, parsing the
command, decoding the hex and writing to the pane pty: the floor under
anything tmm can achieve in compositor mode, and the part we do not own.
"""
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from keylag import PROBE, arrivals, clock_ns, report_noise, floor_verdict  # noqa: E402

N = 40


def run(load, gap=0.05):
    with tempfile.TemporaryDirectory(prefix='tmux-floor-', dir='/tmp') as root:
        log = os.path.join(root, 'probe.log')
        sock = os.path.join(root, 'sock')

        def tmux(*a, check=True):
            r = subprocess.run(['tmux', '-S', sock, *a], capture_output=True, timeout=10)
            if check and r.returncode:
                raise AssertionError(r.stderr.decode())
            return r.stdout.decode()

        tmux('new-session', '-d', '-s', 't', '-x', '160', '-y', '40',
             '%s --log %s%s' % (PROBE, log, ' --load' if load else ''))
        time.sleep(1.0)
        pane = tmux('display-message', '-p', '-t', 't', '#{pane_id}').strip()

        cc = subprocess.Popen(['tmux', '-S', sock, '-C', 'attach', '-t', 't'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
        drained = [0]

        def drain():
            while True:
                line = cc.stdout.readline()
                if not line:
                    return
                drained[0] += len(line)

        threading.Thread(target=drain, daemon=True).start()
        time.sleep(0.8)

        keys = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN'[:N]
        sent = {}
        for key in keys:
            sent[key] = clock_ns()
            cc.stdin.write(('send-keys -t %s -H %02x\n' % (pane, ord(key))).encode())
            cc.stdin.flush()
            time.sleep(gap)
        cc.stdin.write(('send-keys -t %s -H 51\n' % pane).encode())   # Q: stop the probe
        cc.stdin.flush()
        time.sleep(1.2)

        got = arrivals(log)
        cc.stdin.close()
        cc.kill()
        tmux('kill-server', check=False)
        lat = [((got[k] - sent[k]) / 1e6, i) for i, k in enumerate(keys) if k in got]
        return lat, drained[0], len(keys)


def main():
    if not PROBE.exists():
        raise SystemExit('build first: zig build')
    report_noise('tmux floor')
    for load in (False, True):
        lat, drained, n = run(load)
        if not lat:
            print('%-6s no samples' % ('load' if load else 'quiet'))
            continue
        values = sorted(x for x, _ in lat)
        p99 = values[min(len(values) - 1, int(len(values) * 0.99))]
        worst_at = max(lat)[1]
        print('%-6s n=%d/%d  min %6.3f  median %6.3f  p99 %7.3f  MAX %7.3f ms '
              '(worst at sample %d of %d)  %dMB drained'
              % ('load' if load else 'quiet', len(lat), n, values[0],
                 statistics.median(values), p99, values[-1], worst_at, n,
                 drained // (1 << 20)))
        slow = [(i, round(x, 3)) for x, i in sorted(lat) if x > 1.0]
        if slow:
            print('       over 1ms: %s' % slow)
        floor_verdict(slow, len(lat))


if __name__ == '__main__':
    main()
