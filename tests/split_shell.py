#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Drives `tmm --shell`: sidebar, divider, and a real shell in the region.

Only disposable tmux sockets, processes, and files under /tmp are mutated.

The interesting assertions are the ones with effects outside the display: a
command typed into the region has to actually run, and a tmux client attached
inside it has to show up on the server at the region's exact size. Those hold
whatever the blit looks like. The rendering assertions come on top of that.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import sys
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
ROWS, COLS, SPLIT = 40, 120, 30
# The region is everything right of the sidebar and its one-column divider.
REGION_COLS = COLS - SPLIT - 1



def main():
    with tempfile.TemporaryDirectory(prefix='tmm-split-', dir='/tmp') as root:
        socket = root + '/socket'
        children = []
        output = {}
        # One screen per terminal, fed as bytes arrive, so assertions read the
        # display as a user would rather than as a diff stream.
        screens = {}

        def tmux(*args, check=True):
            run = subprocess.run(['tmux', '-S', socket, *args],
                                 capture_output=True, timeout=5)
            if check and run.returncode != 0:
                raise AssertionError(run.stderr.decode())
            return run.stdout.decode()

        def terminal(argv):
            pid, fd = pty.fork()
            if pid == 0:
                os.environ['TERM'] = 'xterm-256color'
                os.environ['SHELL'] = '/bin/sh'
                os.environ['PS1'] = 'rgn$ '
                os.environ.pop('TMUX', None)
                os.execvp(argv[0], argv)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
            children.append((pid, fd))
            return pid, fd

        def pump(duration=0.8):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                ready, _, _ = select.select([fd for _, fd in children], [], [], 0.03)
                for fd in ready:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        continue
                    output.setdefault(fd, bytearray()).extend(data)
                    screens.setdefault(fd, Screen(ROWS, COLS)).feed(data)
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def screen(fd):
            return screens.setdefault(fd, Screen(ROWS, COLS))

        def until(predicate, limit=8, step=0.3):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(step)
                value = predicate()
                if value:
                    return value
            return None

        def clients():
            rows = tmux('list-clients', '-F',
                        '#{client_control_mode}|#{client_width}x#{client_height}|'
                        '#{session_name}').splitlines()
            return [r.split('|', 1)[1] for r in rows if r.startswith('0|')]

        try:
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-c', root)

            ui_pid, ui_fd = terminal([str(BINARY), '-S', socket,
                                      '--shell', '--split', str(SPLIT)])
            assert until(lambda: screen(ui_fd).line(0).startswith('tmm : tmux micro manager')), \
                'sidebar did not render'
            assert until(lambda: 'F12 shell' in screen(ui_fd).line(ROWS - 1)), \
                ('split-mode hint did not render', screen(ui_fd).line(ROWS - 1))
            # The divider is one column, drawn for the full height, and the
            # sidebar stops short of it rather than being clipped by it.
            assert screen(ui_fd).column(SPLIT) == '│' * ROWS, \
                ('divider is not a full-height single column',
                 repr(screen(ui_fd).column(SPLIT)))
            assert all('│' not in line[:SPLIT] for line in screen(ui_fd).lines()), \
                'sidebar drew into the divider'

            # ---- keys reach the child -------------------------------------
            os.write(ui_fd, b'\x1b[24~')  # F12: focus the region
            pump(0.5)
            assert 'F12 sidebar' in screen(ui_fd).line(ROWS - 1), \
                ('focus did not move to the region', screen(ui_fd).line(ROWS - 1))

            os.write(ui_fd, f'tmux -S {socket} new-session -d -s from_region\r'.encode())
            assert until(lambda: 'from_region' in tmux('list-sessions', '-F',
                                                       '#{session_name}')), \
                'command typed into the region never ran'

            # ---- the child's output is blitted back out ------------------
            os.write(ui_fd, b'echo tmm-region-marker\r')
            # Only the region's own columns, so this cannot pass on an echo
            # that leaked into the sidebar.
            assert until(lambda: any('tmm-region-marker' in line
                                     for line in screen(ui_fd).region(SPLIT + 1))), \
                ('region output never reached the display',
                 screen(ui_fd).region(SPLIT + 1))

            # ---- a real tmux client attaches inside the region -----------
            before = clients()
            os.write(ui_fd, f'tmux -S {socket} attach -t alpha\r'.encode())
            attached = until(lambda: [c for c in clients() if c not in before])
            assert attached, 'tmux attach inside the region did not reach the server'
            size, _, session = attached[0].partition('|')
            assert session == 'alpha', attached
            # The pty was sized to the region, not to the whole window: this is
            # what makes the attached client lay itself out correctly.
            assert size == f'{REGION_COLS}x{ROWS}', (size, f'{REGION_COLS}x{ROWS}')
            # The attached client draws a status line along its bottom row,
            # naming the session. Seeing it means a full-screen program inside
            # the region renders through our terminal.
            assert until(lambda: 'alpha' in screen(ui_fd).region(SPLIT + 1)[ROWS - 1]), \
                ('the attached tmux status line never rendered',
                 screen(ui_fd).region(SPLIT + 1)[ROWS - 1])

            # ---- dragging the divider resizes both sides -----------------
            new_split = SPLIT + 20
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 1};5M'.encode())        # press on divider
            os.write(ui_fd, f'\x1b[<32;{new_split + 1};5M'.encode())   # drag right
            os.write(ui_fd, f'\x1b[<0;{new_split + 1};5m'.encode())    # release
            expect = f'{COLS - new_split - 1}x{ROWS}'
            resized = until(lambda: [c for c in clients() if c.startswith(expect)])
            assert resized, ('divider drag did not resize the region', clients(), expect)
            assert until(lambda: screen(ui_fd).column(new_split) == '\u2502' * ROWS), \
                ('the divider did not move with the drag',
                 repr(screen(ui_fd).column(new_split)))

            # ---- the sidebar still works after all that ------------------
            os.write(ui_fd, b'\x1b[24~')  # F12: back to the sidebar
            pump(0.5)
            assert 'F12 shell' in screen(ui_fd).line(ROWS - 1), \
                ('focus did not return to the sidebar', screen(ui_fd).line(ROWS - 1))

            os.write(ui_fd, b'q')
            done, status = 0, 0
            deadline = time.monotonic() + 8
            while done == 0 and time.monotonic() < deadline:
                pump(0.2)
                done, status = os.waitpid(ui_pid, os.WNOHANG)
            assert done == ui_pid, ('UI did not exit', repr(bytes(output[ui_fd][-2000:])))
            assert os.waitstatus_to_exitcode(status) == 0, bytes(output[ui_fd][-2000:])
            children.remove((ui_pid, ui_fd))
            # The shell and the tmux client inside it go with it.
            assert until(lambda: not clients()), ('region clients outlived tmm', clients())
            print('ok')
        finally:
            for pid, fd in children:
                try:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
                except OSError:
                    pass
                try:
                    os.close(fd)
                except OSError:
                    pass
            subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)


if __name__ == '__main__':
    main()
