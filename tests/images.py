#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""An image a program draws in the region has to reach the outer terminal.

The outer terminal is emulated, and claims kitty graphics support, so the
sequences tmm emits on the program's behalf can be read back. libvaxis only
sets that capability when a reply to its query arrives, and the query is
`\\x1b_Gi=1,a=q` with no semicolon in it, so the reply has to be given here
or tmm correctly concludes the display cannot show images.

The assertion that matters is on the bytes: the pixels the program
transmitted have to arrive at the outer terminal unchanged, base64 and all.
A test that only checked an APC was emitted passed while the payload was
going out raw -- which a real terminal would have torn in half at the first
pixel that happened to be 0x1b.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import base64
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROWS, COLS, SPLIT = 40, 170, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
# Four pixels wide, two rows: red, green, blue, yellow, twice.
PIXELS = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0] * 2)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    payload = base64.b64encode(PIXELS).decode()
    with tempfile.TemporaryDirectory(prefix='tmm-images-', dir='/tmp') as root:
        child = os.path.join(root, 'child.sh')
        Path(child).write_text(
            '#!/bin/sh\n'
            'printf "\\033[5;3H"\n'
            'printf "\\033_Gf=24,s=4,v=2,a=T,i=7;' + payload + '\\033\\\\"\n'
            'sleep 300\n')
        os.chmod(child, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'i'],
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
                ready, _, _ = select.select([fd], [], [], 0.02)
                for f in ready:
                    try:
                        data = os.read(f, 1 << 16)
                    except OSError:
                        return
                    seen.extend(data)
                    if b'\x1b[c' in data:
                        os.write(fd, b'\x1b[?62;4c')
                    # This terminal does kitty graphics. Without the reply
                    # libvaxis leaves the capability off and nothing is sent.
                    if b'a=q' in data and not answered:
                        answered.append(True)
                        os.write(fd, b'\x1b_Gi=1;OK\x1b\\')

        try:
            pump(4.0)
            assert answered, 'tmm never queried for kitty graphics support'
            out = bytes(seen)
            apcs = re.findall(rb'\x1b_G([^\x1b]*)\x1b\\', out)
            transmits = [a for a in apcs if b'f=24' in a or b'f=32' in a]
            assert transmits, ('no image was transmitted to the outer terminal',
                               [a[:40] for a in apcs])
            head, _, body = transmits[0].partition(b';')
            assert b's=4' in head and b'v=2' in head, \
                ('the image went out at the wrong size', head)
            # The payload has to be base64 of exactly what the program sent.
            # Raw pixels here would be a protocol violation that happens to
            # work until a pixel equals 0x1b.
            assert body, ('the transmission carried no payload', head)
            try:
                decoded = base64.b64decode(body, validate=True)
            except Exception as err:
                raise AssertionError(('the payload is not valid base64', body[:40], err))
            assert decoded == PIXELS, \
                ('the pixels changed on the way out', decoded[:12], PIXELS[:12])
            assert any(b'a=p' in a for a in apcs), \
                ('the image was transmitted but never placed', [a[:40] for a in apcs])
            print('ok: %d bytes of pixels reached the outer terminal unchanged, '
                  'transmitted once and placed' % len(decoded))
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


if __name__ == '__main__':
    main()
