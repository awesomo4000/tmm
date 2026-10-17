#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A program inside tmm has to be able to find out how big a cell is.

That is the question an image viewer asks before it will draw anything, and
there are two ways to ask: the `TIOCGWINSZ` pixel fields, and the XTWINOPS
queries `CSI 14 t` (text area in pixels) and `CSI 16 t` (cell size). Viewers
disagree about which to use -- `tools/image-emission.py` measured chafa
querying, and `kitty icat` consulting the ioctl only and refusing outright on
a zero -- so both have to answer, and neither may invent a number.

The outer terminal here is a pty whose window size carries pixels, which is
where the cell size comes from: 10 by 20. Nothing else in tmm knows it.

The region owns its pty, so both routes are checked there and both have to
give the real size.

A tmux pane is not tmm's to answer, and the second half of this test pins
that rather than wishing otherwise. tmux owns the pane pty and fills its
pixel fields from a hardcoded 16 by 32 cell whenever no terminal client
reports a real one, which a control-mode client cannot: `refresh-client -C`
takes cells, and every pixel-carrying spelling of it was tried and parsed as
cells. tmux also answers `CSI 16 t` from the pane itself, out of that same
assumption, so the query never reaches tmm either. Both routes therefore
carry a plausible wrong number that a program cannot tell from a right one.
Pinning it means that if tmux ever propagates a real cell size, this test
fails and the limitation gets revisited instead of being carried forever in
a comment.

Replies are read in raw mode. A canonical-mode read waits for a newline that
an escape sequence never contains, which has cost this suite time before.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
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

# Asks both ways and records what came back. Run as the program inside.
INNER = r'''
import fcntl, termios, struct, sys, os, select, time, tty
out = {}
w = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
rows, cols, xp, yp = struct.unpack("HHHH", w)
out["ioctl"] = "%d %d %d %d" % (rows, cols, xp, yp)
try:
    tty.setraw(sys.stdin.fileno())
except Exception as err:
    out["raw"] = "failed: %s" % err
for name, seq in (("csi16", "\x1b[16t"), ("csi14", "\x1b[14t"), ("csi18", "\x1b[18t")):
    sys.stdout.write(seq)
    sys.stdout.flush()
    got, until = b"", time.monotonic() + 2.0
    while time.monotonic() < until:
        r, _, _ = select.select([sys.stdin.fileno()], [], [], 0.05)
        if r:
            got += os.read(sys.stdin.fileno(), 256)
            if got.endswith(b"t"):
                break
    out[name] = got.decode("latin1")
open(ANSWER, "w").write("\n".join("%s=%s" % kv for kv in out.items()))
time.sleep(300)
'''


def run(argv, env, answer_path, duration=8.0):
    """Run argv under a pty that reports a pixel size, and collect the answer."""
    if os.path.exists(answer_path):
        os.unlink(answer_path)
    pid, fd = pty.fork()
    if pid == 0:
        for stale in ('TMUX', 'TMUX_PANE'):
            os.environ.pop(stale, None)
        os.environ['TERM'] = 'xterm-256color'
        os.environ.update(env)
        try:
            os.execvp(argv[0], argv)
        except Exception:
            os._exit(127)
    # The pixel fields here are the only source of the cell size in the test.
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', ROWS, COLS, COLS * CELL_W, ROWS * CELL_H))
    until = time.monotonic() + duration
    while time.monotonic() < until:
        ready, _, _ = select.select([fd], [], [], 0.05)
        for f in ready:
            try:
                if not os.read(f, 1 << 16):
                    until = 0
            except OSError:
                until = 0
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
    try:
        text = Path(answer_path).read_text()
    except OSError:
        raise AssertionError('the program inside never reported; it may not '
                             'have started')
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-sizereport-', dir='/tmp') as root:
        answer = os.path.join(root, 'answer.txt')
        inner = os.path.join(root, 'inner.py')
        Path(inner).write_text('ANSWER = %r\n' % answer + INNER)
        script = os.path.join(root, 'inner.sh')
        Path(script).write_text('#!/bin/sh\nexec %s %s\n' % (sys.executable, inner))
        os.chmod(script, 0o755)
        conf = os.path.join(root, 'tmux.conf')
        Path(conf).write_text('set -g allow-passthrough on\n')

        # The region: tmm owns this pty, so both routes must answer.
        sock = os.path.join(root, 'sock')
        subprocess.run(['tmux', '-S', sock, '-f', conf,
                        'new-session', '-d', '-s', 's'],
                       capture_output=True, timeout=10)
        got = run([str(BINARY), '-S', sock, '--shell', '--split', str(SPLIT)],
                  {'SHELL': script}, answer)

        rows, cols, xp, yp = (int(v) for v in got['ioctl'].split())
        assert xp == cols * CELL_W, \
            ('the region pty reported the wrong pixel width',
             xp, cols * CELL_W, got['ioctl'])
        assert yp == rows * CELL_H, \
            ('the region pty reported the wrong pixel height',
             yp, rows * CELL_H, got['ioctl'])

        # CSI 16 t answers with the cell size, which is the whole point: it is
        # the one number tmm cannot derive and had to be told.
        assert got.get('csi16') == '\x1b[6;%d;%dt' % (CELL_H, CELL_W), \
            ('CSI 16 t gave the wrong cell size', repr(got.get('csi16')))
        assert got.get('csi14') == '\x1b[4;%d;%dt' % (rows * CELL_H, cols * CELL_W), \
            ('CSI 14 t gave the wrong text area', repr(got.get('csi14')))
        assert got.get('csi18') == '\x1b[8;%d;%dt' % (rows, cols), \
            ('CSI 18 t gave the wrong cell counts', repr(got.get('csi18')))
        print('ok: the region answers the ioctl (%dx%d px) and CSI 14/16/18 t'
              % (xp, yp))

        # A tmux pane: tmux owns the pty and a control client cannot report
        # pixels to it, so the ioctl is expected to stay zero and the query is
        # the only route. Asserting the zero keeps the limitation honest: if
        # tmux ever does propagate it, this fails and gets revisited.
        subprocess.run(['tmux', '-S', sock, 'kill-server'],
                       capture_output=True, timeout=10)
        subprocess.run(['tmux', '-S', sock, '-f', conf,
                        'new-session', '-d', '-s', 's', script],
                       capture_output=True, timeout=10)
        got = run([str(BINARY), '-S', sock, '--split', str(SPLIT)], {}, answer,
                  duration=10.0)
        pane_rows, pane_cols, pane_xp, pane_yp = (int(v) for v in got['ioctl'].split())
        # tmux's own assumption, measured: 16 wide by 32 high, nothing to do
        # with the 10 by 20 the outer terminal actually has.
        assert (pane_xp, pane_yp) == (pane_cols * 16, pane_rows * 32), \
            ('tmux no longer fabricates a 16x32 cell for a control client; if '
             'it now propagates a real one, tmm may be able to stop treating '
             'panes as unreachable', got['ioctl'], pane_cols, pane_rows)
        # And tmux answers the query out of the same assumption, which is why
        # tmm cannot correct this from its side: the query never arrives.
        assert got.get('csi16') == '\x1b[6;32;16t', \
            ('a pane CSI 16 t no longer comes back as tmux 16x32; if it now '
             'reaches tmm, wire the real cell size through and assert it '
             'here instead', repr(got.get('csi16')))
        assert got.get('csi16') != '\x1b[6;%d;%dt' % (CELL_H, CELL_W), \
            'a pane unexpectedly reported the real cell size'
        print('ok: a pane is answered by tmux from its own 16x32 assumption, '
              'on both routes, so tmm cannot reach it and does not pretend to')
        subprocess.run(['tmux', '-S', sock, 'kill-server'],
                       capture_output=True, timeout=10)


if __name__ == '__main__':
    main()
