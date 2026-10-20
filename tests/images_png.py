#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A PNG transmission has to survive the region, not be dropped in it.

`kitty icat` and timg transmit PNG (`f=100`) rather than raw pixels, and
libghostty-vt cannot decode one itself: it calls out through a
`sys.decode_png` function pointer that is null in a library build, and a null
pointer there fails the load, so the image was silently discarded. chafa was
unaffected because it sends raw RGBA, which is why this went unnoticed while
tests/images.py passed. src/png.zig installs the decoder.

This is the same proof as tests/images.py with the one difference that
matters: the program inside sends a compressed PNG, and what must arrive at
the outer terminal is the *decoded* pixels, since that is all a stored kitty
image ever is. So the assertion is end to end over a real decode -- a PNG
goes in one side, and the exact RGBA bytes that PNG encodes come out the
other as `f=32`. Reverting the hook makes it fail with nothing transmitted at
all, which is the state this test was written against.

The PNG is built here with zlib rather than read from a file, so the harness
needs no fixture and the expected pixels are the ones it encoded.

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
import struct
import subprocess
import sys
import tempfile
import termios
import time
import zlib

ROWS, COLS, SPLIT = 40, 170, 30
# Found rather than spelled out: a path to one checkout runs nowhere else.
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'

WIDTH, HEIGHT = 4, 2
# Red, green, blue, yellow -- the second row at half alpha, so a decode that
# dropped or flattened the alpha channel cannot pass. Deliberately includes
# 0x1b (27) in the green channel of the second row: a payload that went out
# raw instead of base64 would be torn in half there by a real terminal.
PIXELS = bytes([
    255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   255, 255, 0, 255,
    255, 0, 0, 128,   0, 27, 0, 128,    0, 0, 255, 128,   255, 255, 0, 128,
])


def png_bytes(width, height, pixels):
    """An 8-bit RGBA PNG of exactly these pixels, no filtering, one IDAT."""
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

    # Colour type 6 is RGBA; filter byte 0 at the head of each row means the
    # scanline is stored as-is, so the payload is the pixels themselves.
    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    stride = width * 4
    raw = b''.join(
        b'\x00' + pixels[row * stride:(row + 1) * stride]
        for row in range(height))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', header)
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    png = png_bytes(WIDTH, HEIGHT, PIXELS)
    # Compressed, so this is also a check that the payload is not merely
    # passed through: fewer bytes go in than come out.
    assert len(png) < len(PIXELS) + 100, 'the fixture is not a real PNG'
    payload = base64.b64encode(png).decode()

    with tempfile.TemporaryDirectory(prefix='tmm-png-', dir='/tmp') as root:
        child = os.path.join(root, 'child.sh')
        Path(child).write_text(
            '#!/bin/sh\n'
            'printf "\\033[5;3H"\n'
            # f=100 is PNG. No s= or v=: the dimensions come out of the PNG
            # header, which is itself part of what a decoder has to get right.
            'printf "\\033_Gf=100,a=T,i=9;' + payload + '\\033\\\\"\n'
            'sleep 300\n')
        os.chmod(child, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run([TMUX, '-S', socket, 'new-session', '-d', '-s', 'p'],
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
            assert transmits, (
                'the PNG was dropped: nothing was transmitted to the outer '
                'terminal, which is what a null sys.decode_png looks like',
                [a[:40] for a in apcs])
            head, _, body = transmits[0].partition(b';')
            # Decoded RGBA, so four channels and the size read out of the
            # PNG header rather than from the escape sequence.
            assert b'f=32' in head, \
                ('the image went out without its alpha channel', head)
            assert b's=%d' % WIDTH in head and b'v=%d' % HEIGHT in head, \
                ('the size did not come from the PNG header', head)
            assert body, ('the transmission carried no payload', head)
            try:
                decoded = base64.b64decode(body, validate=True)
            except Exception as err:
                raise AssertionError(('the payload is not valid base64', body[:40], err))
            assert decoded == PIXELS, \
                ('the PNG decoded to the wrong pixels', decoded[:16], PIXELS[:16])
            assert any(b'a=p' in a for a in apcs), \
                ('the image was decoded but never placed', [a[:40] for a in apcs])
            print('ok: a %d byte PNG decoded to %d bytes of RGBA and reached the '
                  'outer terminal as the pixels it encoded, placed once'
                  % (len(png), len(decoded)))
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
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)


if __name__ == '__main__':
    main()
