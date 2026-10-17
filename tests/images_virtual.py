#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A virtual placement is positioned by the cells that refer to it.

It is transmitted with `U=1` and carries no position. The program then writes
U+10EEEE placeholder cells, whose foreground colour is the image id and whose
first two combining marks index a table giving which row and column of the
image that cell shows. tmm has to find those cells, group each row's run, and
place the matching slice of the image there.

This is the path every image viewer measured takes once tmux is in the way --
see `tools/image-emission.py` -- so it is not an exotic corner.

The image here is 2 by 2 cells of solid red, and the placeholder grid is
written in full: four cells, two per row, each naming its own row and column.
What the outer terminal must receive is a placement per row, each clipped to
that row's half of the source and scaled into a 2 by 1 cell box.

The outer terminal is emulated and claims kitty graphics support, and it also
has to report a pixel size, because a virtual placement cannot be resolved
without a cell size: `renderPlacement` needs it to turn a cell box into a
source rectangle. That is why `tests/size_report.py` had to come first.

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
CELL_W, CELL_H = 10, 20
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'

IMAGE_ID = 42
CELLS_W, CELLS_H = 2, 2
# 4x4 pixels of red, so each of the four cells has a 2x2 pixel share.
PIXELS = bytes([255, 0, 0] * 16)
PLACEHOLDER = '\U0010eeee'
# Index into the protocol's diacritic table is the row or column number.
DIACRITICS = ['̅', '̍', '̎', '̐']


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    payload = base64.b64encode(PIXELS).decode()
    # The id travels in the foreground colour of each placeholder cell; for an
    # id under 256 the palette form carries it directly.
    grid = ''
    for row in range(CELLS_H):
        grid += '\x1b[%d;3H\x1b[38;5;%dm' % (6 + row, IMAGE_ID)
        for col in range(CELLS_W):
            grid += PLACEHOLDER + DIACRITICS[row] + DIACRITICS[col]
    grid += '\x1b[39m'

    with tempfile.TemporaryDirectory(prefix='tmm-virtual-', dir='/tmp') as root:
        child = os.path.join(root, 'child.sh')
        Path(child).write_text(
            '#!/bin/sh\n'
            # U=1 marks the placement virtual; c= and r= give its cell extent.
            "printf '\\033_Ga=T,U=1,i=%d,f=24,s=4,v=4,c=%d,r=%d;%s\\033\\\\'\n"
            % (IMAGE_ID, CELLS_W, CELLS_H, payload)
            + "printf '%s'\n" % grid.replace('\x1b', '\\033')
            + 'sleep 300\n')
        os.chmod(child, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run(['tmux', '-S', socket, '-f', '/dev/null',
                        'new-session', '-d', '-s', 'v'],
                       capture_output=True, timeout=10)

        pid, fd = pty.fork()
        if pid == 0:
            for stale in ('TMUX', 'TMUX_PANE'):
                os.environ.pop(stale, None)
            os.environ['TERM'] = 'xterm-256color'
            os.environ['SHELL'] = child
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                    '--split', str(SPLIT)])
        # The pixel size is what lets a virtual placement be resolved at all.
        fcntl.ioctl(fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', ROWS, COLS, COLS * CELL_W, ROWS * CELL_H))

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
                    if b'a=q' in data and not answered:
                        answered.append(True)
                        os.write(fd, b'\x1b_Gi=1;OK\x1b\\')

        try:
            pump(6.0)
            assert answered, 'tmm never queried for kitty graphics support'
            out = bytes(seen)
            apcs = re.findall(rb'\x1b_G([^\x1b]*)\x1b\\', out)
            # Placements, as opposed to the transmission, carry a=p.
            places = [a for a in apcs if b'a=p' in a]
            assert places, ('the virtual placement was never placed',
                            [a[:48] for a in apcs])

            def field(spec, key):
                m = re.search(rb'(?:^|,)%s=(-?\d+)' % key, spec)
                return int(m.group(1)) if m else None

            # Every frame re-emits its placements -- libvaxis keeps one only
            # for the frame it was drawn in -- so the distinct strips are what
            # matters, not how many times they were sent.
            strips = {(field(p, b'c'), field(p, b'r'), field(p, b'y') or 0,
                       field(p, b'h')) for p in places}
            boxes = {(c, r) for c, r, _, _ in strips}
            assert boxes == {(CELLS_W, 1)}, \
                ('a placement was not a %d by 1 cell strip' % CELLS_W,
                 sorted(boxes), [p[:60] for p in places])
            assert len(strips) == CELLS_H, \
                ('expected one distinct strip per image row',
                 sorted(strips), CELLS_H)

            # Each row shows its own horizontal slice of the source, so the
            # vertical offsets into the image have to differ. Equal offsets
            # would draw the same strip twice and still look plausible.
            ys = sorted({y for _, _, y, _ in strips})
            assert len(ys) == CELLS_H, \
                ('the rows all drew the same slice of the source', ys,
                 sorted(strips))
            heights = {h for _, _, _, h in strips}
            rows_seen = strips
            print('ok: a virtual placement reached the outer terminal as %d '
                  'row strips, source y offsets %s, heights %s, each in a '
                  '%dx1 cell box'
                  % (len(rows_seen), ys, sorted(heights), CELLS_W))
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
