#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""tmm and tmux agree on which pane has the keyboard.

Two things kept them apart, and both matter the moment the prefix works,
because a tmux binding acts on the pane *tmux* considers active rather than
the one being typed in.

The keyboard started in the wrong place. tmm set its focus to whichever pane
was created first, so attaching to a session whose active pane was the second
one typed into the first. tmux never says "the active pane is X" at attach --
`%window-pane-changed` fires on a change -- so it has to be asked, and
`adoptWindow` already runs a `list-panes` whose format now carries
`#{pane_active}`.

And a click moved only tmm. Clicking a pane pointed the keyboard at it and
left tmux's active pane alone, so `prefix z` zoomed a pane you were not
typing in. A click now runs `select-pane` as well.

The third case is the one that shows why this is worth a test rather than a
note: it presses a real binding after a click and checks which pane it acted
on. That is the symptom somebody would actually hit.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import os
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'
ROWS, COLS = 40, 170


def answer(fd, data):
    """Reply to the queries vaxis makes, including the kitty keyboard one.

    Kitty flags are reported because the chords here are ctrl chords, and in
    the legacy encoding those collide with control bytes.
    """
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        os.write(fd, b'\x1b[?31u')


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')

    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-focus-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args, check=False):
            r = subprocess.run([TMUX, '-S', socket, *args],
                               capture_output=True, text=True, timeout=15)
            if check:
                assert r.returncode == 0, (args, r.stderr)
            return r.stdout

        conf = os.path.join(root, 'conf')
        with open(conf, 'w') as f:
            f.write('set -g prefix C-b\n'
                    'bind z resize-pane -Z\n')
        tmux('-f', conf, 'new-session', '-d', '-s', 's', '-x', '120', '-y', '30',
             check=True)
        tmux('split-window', '-h', '-t', 's', check=True)
        panes = tmux('list-panes', '-t', 's', '-F', '#{pane_id}').split()
        assert len(panes) == 2, panes
        left, right = panes
        # Deliberately the SECOND pane, decided before tmm ever attaches, so
        # "whichever was created first" is the wrong answer.
        tmux('select-pane', '-t', right, check=True)
        time.sleep(0.4)

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        def pump(duration):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                for _ in select.select([fd], [], [], 0.02)[0]:
                    try:
                        data = os.read(fd, 1 << 16)
                    except OSError:
                        return
                    answer(fd, data)

        def active():
            return tmux('display-message', '-p', '-t', 's', '#{pane_id}').strip()

        def marks(pane):
            return tmux('capture-pane', '-p', '-t', pane).count('Z')

        def clear_both():
            for p in (left, right):
                tmux('send-keys', '-t', p, 'C-u')
            pump(0.5)

        def click(col, row=10):
            os.write(fd, ('\x1b[<0;%d;%dM' % (col, row)).encode())
            pump(0.4)
            os.write(fd, ('\x1b[<0;%d;%dm' % (col, row)).encode())
            pump(0.5)

        try:
            pump(4.0)
            os.write(fd, b'\x00')      # ctrl+` : keyboard to the region
            pump(0.8)

            # 1. The keyboard starts at the pane tmux has active, not at the
            #    first one created.
            clear_both()
            os.write(fd, b'\x1b[90;1u')        # type Z
            pump(1.0)
            if marks(right) != 1 or marks(left) != 0:
                failures.append('the keyboard did not start at the pane tmux '
                                'had active: left got %d, right got %d'
                                % (marks(left), marks(right)))

            # 2. Clicking a pane moves tmux's active pane too. The sidebar
            #    ends around column 34, so column 45 is inside the left pane.
            clear_both()
            click(45)
            if active() != left:
                failures.append('clicking the left pane left tmux active on '
                                '%s' % active())

            # 3. And the symptom that matters: a binding pressed after the
            #    click acts on the pane that was clicked.
            os.write(fd, b'\x1b[98;5u')        # C-b, the prefix
            pump(0.4)
            os.write(fd, b'z')                 # resize-pane -Z
            pump(0.9)
            zoomed = tmux('list-panes', '-t', 's', '-F',
                          '#{pane_id} #{window_zoomed_flag} #{pane_active}')
            if ('%s 1 1' % left) not in zoomed:
                failures.append('prefix z after a click did not act on the '
                                'clicked pane: %r' % zoomed.replace('\n', ' | '))
            os.write(fd, b'\x1b[98;5u')
            pump(0.3)
            os.write(fd, b'z')                 # unzoom, for the last case
            pump(0.8)

            # 4. Clicking back the other way, so neither direction is a
            #    one-off and typing follows the click as well.
            clear_both()
            click(150)
            if active() != right:
                failures.append('clicking the right pane left tmux active on '
                                '%s' % active())
            os.write(fd, b'\x1b[90;1u')
            pump(1.0)
            if marks(right) != 1 or marks(left) != 0:
                failures.append('typing did not follow the click: left got '
                                '%d, right got %d' % (marks(left), marks(right)))
        finally:
            os.write(fd, b'q')
            time.sleep(0.5)
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
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: the keyboard starts at the pane tmux has active, a click moves '
          'tmux active pane with it, and a binding pressed after a click acts '
          'on the pane that was clicked')


if __name__ == '__main__':
    main()
