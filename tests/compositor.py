#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Drives `tmm --panes`: tmm is the terminal for each tmux pane.

Only disposable tmux sockets, processes, and files under /tmp are mutated.

The assertions that matter are the ones with effects outside the display:
output written by a pane process has to reach the right pane's grid, and a
keystroke has to reach the focused pane's process. Those hold whatever the
blit looks like. Nothing here goes through tmux's own terminal emulation:
output arrives as raw `%output` and input leaves as `send-keys -H`.
"""
import fcntl
import os
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
from screen import Screen  # noqa: E402
import keys  # noqa: E402

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
ROWS, COLS, SPLIT = 40, 160, 30
# Everything right of the sidebar and its one-column divider.
REGION = COLS - SPLIT - 1


def main():
    with tempfile.TemporaryDirectory(prefix='tmm-panes-', dir='/tmp') as root:
        socket = root + '/socket'
        children = []
        screens = {}

        def tmux(*args, check=True):
            run = subprocess.run(['tmux', '-S', socket, *args],
                                 capture_output=True, timeout=5)
            if check and run.returncode != 0:
                raise AssertionError(run.stderr.decode())
            return run.stdout.decode()

        def pump(duration=0.6):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                ready, _, _ = select.select([fd for _, fd in children], [], [], 0.03)
                for fd in ready:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        continue
                    screens.setdefault(fd, Screen(ROWS, COLS)).feed(data)
                    if b'\x1b[c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def screen(fd):
            return screens.setdefault(fd, Screen(ROWS, COLS))

        def until(predicate, limit=10, step=0.3):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(step)
                value = predicate()
                if value:
                    return value
            return None

        def region():
            return screen(ui_fd).region(SPLIT + 1)

        def column_of(text):
            """Which region column `text` starts at, or None."""
            for line in region():
                at = line.find(text)
                if at != -1:
                    return at
            return None

        try:
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-c', root)
            # Printed before tmm attaches, so it can only reach the display
            # through the seed: tmm asks tmux for the pane's existing screen
            # with a one-shot `capture-pane`. That cannot go down the control
            # stream, because a reply matched by arrival order races the
            # keystrokes the display thread is writing to the same stdin.
            tmux('send-keys', '-t', 'alpha', 'printf BEFORE-ATTACH\\n', 'Enter')
            time.sleep(0.6)

            pid, fd = pty.fork()
            if pid == 0:
                os.environ['TERM'] = 'xterm-256color'
                os.environ['SHELL'] = '/bin/sh'
                os.environ.pop('TMUX', None)
                os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                        '--session', 'alpha', '--split', str(SPLIT)])
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
            children.append((pid, fd))
            ui_fd = fd
            assert until(lambda: any('BEFORE-ATTACH' in line for line in region())), \
                ('a pane that printed before tmm attached was not seeded', region()[-6:])

            # tmm tells tmux how much room it has with refresh-client -C and
            # tmux re-tiles to it, so the client reaching the region's exact
            # width is proof the command arrived and the layout came back.
            # It is also the guard on a sharp edge: tmux takes a blank command
            # line as end of input and answers %exit, detaching the client
            # with no error anywhere, so a stray newline kills the compositor
            # on its first command.
            sized = until(lambda: [w for w in tmux(
                'list-clients', '-F', '#{client_width}').split() if w == str(REGION)])
            assert sized, ('tmux never re-tiled to the region width',
                           tmux('list-clients', '-F', '#{client_width}'))

            # ---- a pane's output reaches its own grid --------------------
            tmux('send-keys', '-t', 'alpha', 'echo PANE-ONE-MARK', 'Enter')
            assert until(lambda: any('PANE-ONE-MARK' in line for line in region())), \
                ('pane output never reached the compositor', region()[-6:])

            # ---- a split becomes two grids side by side ------------------
            tmux('split-window', '-t', 'alpha', '-h')
            tmux('send-keys', '-t', 'alpha.1', 'echo PANE-TWO-MARK', 'Enter')
            assert until(lambda: any('PANE-TWO-MARK' in line for line in region())), \
                ('the second pane never rendered', region()[-6:])
            left = column_of('PANE-ONE-MARK')
            right = column_of('PANE-TWO-MARK')
            assert left is not None and right is not None and right > left, \
                ('panes are not laid out side by side', left, right)
            # tmux leaves a column between panes and draws its border on its
            # own screen, which we never see, so the compositor draws it.
            border = until(lambda: [c for c in range(REGION)
                                    if screen(ui_fd).column(SPLIT + 1 + c)
                                    .count('│') >= ROWS - 2])
            assert border, 'no pane border was drawn between the two panes'
            assert left < border[0] < right, \
                ('the border is not between the panes', left, border, right)

            # ---- a keystroke reaches the focused pane's process ----------
            # This is the half tmux cannot do for us: tmm encodes the key
            # itself and injects the bytes with send-keys -H. Each pane gets
            # its own directory, so where a typed command lands says which
            # pane actually received it.
            ids = tmux('list-panes', '-t', 'alpha', '-F', '#{pane_id}').split()
            first, second = ids[0], ids[1]
            os.mkdir(root + '/one')
            os.mkdir(root + '/two')
            tmux('send-keys', '-t', first, f'cd {root}/one', 'Enter')
            tmux('send-keys', '-t', second, f'cd {root}/two', 'Enter')
            pump(0.8)

            os.write(ui_fd, keys.FOCUS)       # focus the pane region
            pump(0.5)
            # Click the left pane, type, and the file must land in its
            # directory and not the other one.
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 1 + left + 1};20M'.encode())
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 1 + left + 1};20m'.encode())
            pump(0.5)
            os.write(ui_fd, b'touch MARK\r')
            assert until(lambda: Path(root, 'one', 'MARK').exists()), \
                ('a keystroke never reached the left pane',
                 os.listdir(root + '/one'), os.listdir(root + '/two'))
            assert not Path(root, 'two', 'MARK').exists(), \
                'the keystroke went to the wrong pane'

            # Now the right one. Nothing else changed, so the click is the
            # only thing that can have moved the keyboard.
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 1 + right + 1};20M'.encode())
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 1 + right + 1};20m'.encode())
            pump(0.5)
            os.write(ui_fd, b'touch MARK\r')
            assert until(lambda: Path(root, 'two', 'MARK').exists()), \
                ('a click did not move the keyboard to the clicked pane',
                 os.listdir(root + '/one'), os.listdir(root + '/two'))

            # ---- closing a pane removes its grid -------------------------
            tmux('kill-pane', '-t', 'alpha.1')
            assert until(lambda: not any('PANE-TWO-MARK' in line for line in region())), \
                ('a killed pane kept its grid', region()[-6:])
            print('ok')
        finally:
            for pid, fd in children:
                try:
                    os.kill(pid, 9)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if os.waitpid(pid, os.WNOHANG)[0]:
                            break
                        time.sleep(0.05)
                except OSError:
                    pass
                try:
                    os.close(fd)
                except OSError:
                    pass
            subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)


if __name__ == '__main__':
    main()
