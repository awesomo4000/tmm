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
import os, subprocess, sys, tempfile, threading, time, statistics
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import keylag

N = 40

def run(load):
    with tempfile.TemporaryDirectory(prefix='tmux-floor-', dir='/tmp') as root:
        marker = os.path.join(root, 'marker'); open(marker, 'wb').close()
        child = os.path.join(root, 'child.py'); Path(child).write_text(keylag.CHILD)
        sock = os.path.join(root, 'sock')
        def tmux(*a, check=True):
            r = subprocess.run(['tmux', '-S', sock, *a], capture_output=True, timeout=10)
            if check and r.returncode: raise AssertionError(r.stderr.decode())
            return r.stdout.decode()
        tmux('new-session', '-d', '-s', 't', '-x', '160', '-y', '40',
             '-e', 'LAG_MARKER=%s' % marker,
             '-e', 'LAG_LOAD=%d' % (1 if load else 0),
             '%s %s' % (sys.executable, child))
        time.sleep(1.2)
        pane = tmux('display-message', '-p', '-t', 't', '#{pane_id}').strip()

        cc = subprocess.Popen(['tmux', '-S', sock, '-C', 'attach', '-t', 't'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
        # The control client must drain %output or tmux blocks on the pipe.
        drained = [0]
        def drain():
            while True:
                line = cc.stdout.readline()
                if not line: return
                drained[0] += len(line)
        threading.Thread(target=drain, daemon=True).start()
        time.sleep(0.8)

        sent = {}
        keys = [chr(ord('a') + (i % 26)) for i in range(N)]
        # Distinct keys would repeat past 26, so each send is timed by index
        # and matched by order of arrival instead.
        order = []
        for i, k in enumerate(keys):
            t0 = time.monotonic()
            cc.stdin.write(('send-keys -t %s -H %02x\n' % (pane, ord(k))).encode())
            cc.stdin.flush()
            order.append(t0)
            time.sleep(0.05)
        time.sleep(1.5)

        arrivals = []
        for line in Path(marker).read_bytes().decode(errors='replace').splitlines():
            try:
                raw, stamp = line.rsplit(' ', 1)
                arrivals.append(float(stamp))
            except Exception:
                pass
        cc.stdin.close(); cc.kill()
        tmux('kill-server', check=False)
        if len(arrivals) < N:
            print('  only %d of %d keys arrived' % (len(arrivals), N))
        lat = [(a - t) * 1000.0 for a, t in zip(arrivals, order)]
        return [x for x in lat if x >= 0], drained[0]

for load in (False, True):
    lat, drained = run(load)
    if not lat:
        print('%-6s no samples' % ('load' if load else 'quiet')); continue
    o = sorted(lat)
    p99 = o[min(len(o) - 1, int(len(o) * 0.99))]
    print('%-6s n=%-3d min %5.2f  median %5.2f  p99 %6.2f  MAX %6.2f ms   (%d bytes of %%output drained)'
          % ('load' if load else 'quiet', len(o), o[0], statistics.median(o), p99, o[-1], drained))
