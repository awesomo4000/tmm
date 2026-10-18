#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A key release has to reach the program inside the region.

The outer terminal is emulated here, which is the only way to answer this:
the harness honours the flags tmm pushes and then sends a release the way a
kitty-capable terminal would. libvaxis asks for presses only by default, so
without tmm overriding that, a release is never reported to tmm and nothing
downstream can deliver what was never received.

Both a text key and a bare modifier are checked. The modifier is the
interesting one: it is reported only under the all-as-escape-codes flag, and
mishandling it is what once inserted a blank-looking U+E061 into vi.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
import re
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import keys  # noqa: E402

ROWS, COLS, SPLIT = 40, 170, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
SCOPE = Path(__file__).resolve().parent / 'keyscope.py'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-release-', dir='/tmp') as root:
        log = os.path.join(root, 'events.log')
        runner = os.path.join(root, 'run.sh')
        Path(runner).write_text('#!/bin/sh\nexec %s %s --no-blast --no-echo --log %s\n'
                                % (sys.executable, SCOPE, log))
        os.chmod(runner, 0o755)
        socket = os.path.join(root, 'sock')
        subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'r'],
                       capture_output=True, timeout=10)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ.pop('TMUX', None)
            os.environ['SHELL'] = runner
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                    '--split', str(SPLIT)])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        # Every byte tmm writes, so the flag push can be matched exactly.
        # Scanning from one escape to the next `u` spans other sequences and
        # finds nonsense: tmm emits `\x1b[>0q` and `\x1b[?u` around it.
        seen = bytearray()

        def pushed_flags():
            found = re.findall(rb'\x1b\[>(\d+)u', bytes(seen))
            return [int(f) for f in found]

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
                        os.write(fd, b'\x1b[?62;c')
                    if b'\x1b[?u' in data:
                        os.write(fd, b'\x1b[?31u')      # this terminal's flags

        try:
            pump(2.0)
            # The push follows tmm's own flags query, so give it a moment
            # more rather than deciding on the first two seconds.
            for _ in range(6):
                if pushed_flags():
                    break
                pump(0.5)
            flags = pushed_flags()
            assert flags, ('tmm pushed no kitty keyboard flags', bytes(seen[-200:]))
            asked = flags[-1]
            # Bit 2 is report-event-types. Without it the terminal sends
            # presses only, whatever the program inside asks for.
            assert asked & 2, ('tmm did not ask for key releases', asked)

            # Split mode starts focused on the region, so no focus key is
            # needed here, and pressing it would take the keyboard away.
            pump(0.5)
            for seq in (b'\x1b[97;1u', b'\x1b[97;1:3u',
                        b'\x1b[57441;1u', b'\x1b[57441;1:3u'):
                os.write(fd, seq)
                pump(0.35)
            os.write(fd, b'\x1b[21~')          # F10: let keyscope write its log
            pump(1.0)

            text = Path(log).read_text() if os.path.exists(log) else ''
            lines = text.splitlines()
            assert any('release' in l and 'cp=97' in l for l in lines), \
                ('the release of a text key never arrived', lines)
            assert any('release' in l and 'cp=57441' in l for l in lines), \
                ('the release of a bare modifier never arrived', lines)
            assert any('press' in l and 'cp=97' in l for l in lines), \
                ('the press went missing while adding releases', lines)
            print('ok: tmm asked for flags %d; press and release of a text key '
                  'and of a bare modifier both reached the program inside' % asked)
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
