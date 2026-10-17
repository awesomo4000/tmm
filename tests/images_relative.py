#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A relative image placement is drawn at its parent's position plus its offsets.

A relative placement (`P=`/`Q=` with `H=`/`V=`) has no position of its own: it
hangs off a parent, and the chain resolves to the root's pin plus the cell
offsets of every link. Resolving it is also what makes it follow the parent
through a scroll, since a pin moves with the content.

The assertion is on where the two placements land. libvaxis positions the
cursor and then emits the placement, so the cursor sequence immediately
before each one says which cell it went to, and the difference between them
must be the offsets the program asked for.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import base64
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

ROWS, COLS, SPLIT = 40, 170, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
PIXELS = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0] * 2)
H_OFFSET, V_OFFSET = 3, 2


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    payload = base64.b64encode(PIXELS).decode()
    with tempfile.TemporaryDirectory(prefix='tmm-imgrel-', dir='/tmp') as root:
        child = os.path.join(root, 'child.sh')
        Path(child).write_text(
            '#!/bin/sh\n'
            'printf "\\033[6;4H"\n'
            # Transmit and place as placement 1: the parent, pinned here.
            'printf "\\033_Gf=24,s=4,v=2,a=T,i=7,p=1;' + payload + '\\033\\\\"\n'
            'sleep 1\n'
            # Placement 2, relative to placement 1, offset by H/V cells.
            'printf "\\033_Ga=p,i=7,p=2,P=7,Q=1,H=%d,V=%d;\\033\\\\"\n' % (H_OFFSET, V_OFFSET) +
            'sleep 300\n')
        os.chmod(child, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run([TMUX, '-S', socket, 'new-session', '-d', '-s', 'i'],
                       capture_output=True, timeout=10)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ.pop('TMUX', None)
            os.environ['SHELL'] = child
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                    '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        seen = bytearray()
        answered = []

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    seen.extend(data)
                    if b'\x1b[c' in data:
                        os.write(fd, b'\x1b[?62;4c')
                    if b'a=q' in data and not answered:
                        answered.append(True)
                        os.write(fd, b'\x1b_Gi=1;OK\x1b\\')

        try:
            pump(6.0)
            out = bytes(seen)
            assert answered, 'tmm never queried for kitty graphics support'

            # Each placement, with the cursor position that preceded it.
            at = []
            for match in re.finditer(rb'\x1b_G([^\x1b]*a=p[^\x1b]*)\x1b\\', out):
                before = out[:match.start()]
                cursor = None
                for cur in re.finditer(rb'\x1b\[(\d+);(\d+)H', before):
                    cursor = (int(cur.group(1)), int(cur.group(2)))
                if cursor:
                    at.append(cursor)
            # Checked by zeroing the resolved offsets in the product: the
            # test does fail, though here rather than on the position below,
            # because two placements on the same cell collapse into one. So a
            # count of one is the signature of offsets being lost, not of a
            # missing relative placement.
            assert len(at) >= 2, \
                ('expected a parent and a relative placement, got %d -- if one, '
                 'the resolved offsets are being dropped' % len(at), at[:4])

            # The two most recent placements are the pair for this frame.
            parent, relative = at[-2], at[-1]
            drow, dcol = relative[0] - parent[0], relative[1] - parent[1]
            assert (dcol, drow) == (H_OFFSET, V_OFFSET), \
                ('the relative placement is not at its parent plus the offsets',
                 {'parent': parent, 'relative': relative,
                  'wanted': (H_OFFSET, V_OFFSET), 'got': (dcol, drow)})
            print('ok: the relative placement landed %d right and %d down from '
                  'its parent, as asked' % (dcol, drow))
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
