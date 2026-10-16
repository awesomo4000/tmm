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

        def region_client(field):
            """A field of the one non-control client, which is the one the
            region attached. tmm itself is the control-mode client."""
            rows = tmux('list-clients', '-F',
                        '#{client_control_mode}|' + field).splitlines()
            found = [r.split('|', 1)[1] for r in rows if r.startswith('0|')]
            return found[0] if len(found) == 1 else None

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

            # ---- non-ASCII survives a redraw it did not take part in ----
            # libvaxis keeps a cell's grapheme slice rather than copying it,
            # and re-renders unchanged cells from the screen it retains. The
            # region therefore cannot hand it bytes from the per-frame arena:
            # a sidebar-only repaint resets that arena and the region's
            # characters turn into fragments of sidebar text. Single-byte
            # ASCII comes from a static table, so only box drawing and symbols
            # ever showed it -- which is everything tmux draws borders with.
            Path(root, 'box.txt').write_text(
                'BOXMARK \u250c\u2500\u2500\u2510 \u2502 \u253c END\n')
            os.write(ui_fd, f'cat {root}/box.txt\r'.encode())
            expect = 'BOXMARK \u250c\u2500\u2500\u2510 \u2502 \u253c END'
            assert until(lambda: any(expect in line for line in
                                     screen(ui_fd).region(SPLIT + 1))), \
                ('box drawing never rendered in the region',
                 screen(ui_fd).region(SPLIT + 1))
            # Churn the outer server so the sidebar repaints several times
            # while the region's own terminal stays clean.
            for i in range(3):
                tmux('new-session', '-d', '-s', f'churn{i}', '-c', root)
                pump(0.4)
                tmux('kill-session', '-t', f'churn{i}')
                pump(0.4)
            assert any(expect in line for line in screen(ui_fd).region(SPLIT + 1)), \
                ('region characters decayed across a sidebar-only redraw',
                 [line.rstrip() for line in screen(ui_fd).region(SPLIT + 1)
                  if 'BOXMARK' in line])
            # A decayed grapheme is invalid UTF-8 of the wrong width, which
            # desynchronises the renderer's column accounting and smears
            # output across the divider into the sidebar. The divider staying
            # whole is the cheapest check for that.
            assert screen(ui_fd).column(SPLIT) == '\u2502' * ROWS, \
                ('output smeared across the divider',
                 repr(screen(ui_fd).column(SPLIT)))
            assert all('\ufffd' not in line for line in screen(ui_fd).lines()), \
                'replacement characters reached the display'

            # ---- a modifier alone is not a key the child wants ----------
            # A program that turns on kitty disambiguation has not asked for
            # modifier-key reports, and decodes `CSI 57441 u` as text: U+E061,
            # which renders blank, so a bare shift press appeared as a space
            # in, say, a vi command line.
            #
            # The child sets the mode and pops it again on its own schedule,
            # because while it is set we cannot drive its shell: a control key
            # is encoded as an escape sequence too, so neither Enter nor
            # ctrl+c reaches the line discipline. The evidence is the echo the
            # pty itself produces for what arrives.
            Path(root, 'probe.sh').write_text(
                "printf '\\033[>1u'\nsleep 2\nprintf '\\033[<u'\necho rgn-ready\n")
            os.write(ui_fd, f'sh {root}/probe.sh\r'.encode())
            pump(0.6)
            marker = len(output[ui_fd])
            for modifier in (57441, 57442, 57443, 57444, 57447):
                os.write(ui_fd, f'\x1b[{modifier};2u'.encode())
            # An ordinary key in the same mode, so this pins the gate to
            # modifiers rather than to kitty mode as a whole.
            os.write(ui_fd, b'\x1b[122;;122u\x1b[113;;113u\x1b[122;;122u')
            assert until(lambda: any('rgn-ready' in line for line in
                                     screen(ui_fd).region(SPLIT + 1))), \
                ('the region child never finished the keyboard-mode probe',
                 screen(ui_fd).region(SPLIT + 1))
            echoed = bytes(output[ui_fd][marker:])
            assert b'zqz' in echoed, \
                ('an ordinary key stopped reaching the child in kitty mode',
                 repr(echoed))
            assert not any(str(m).encode() in echoed for m in
                           (57441, 57442, 57443, 57444, 57447)), \
                ('a modifier pressed alone was forwarded to the child',
                 repr(echoed))
            # The typed `zqz` is still pending on the shell input line. Run it
            # and wait for a clean prompt so what follows starts from one.
            os.write(ui_fd, b'\r')
            os.write(ui_fd, b'echo rgn-clear\r')
            assert until(lambda: any('rgn-clear' in line for line in
                                     screen(ui_fd).region(SPLIT + 1))), \
                'the region shell did not return to a prompt'

            # ---- the region is a real terminal: tmm inside tmm ----------
            # A full-screen libvaxis app is a much harder client than a shell.
            # To draw at all it needs DA1 and DSR answered, the alternate
            # screen, synchronised output, mouse-mode negotiation, colour and
            # a correct size -- and at three levels every one of those has to
            # survive two round trips. This is the property the compositor
            # rests on, so it is worth one slow test.
            banner = 'tmm : tmux micro manager'
            def sidebars():
                row = screen(ui_fd).line(0)
                return [i for i in range(COLS) if row.startswith(banner, i)]

            def focus_deepest():
                # One click focuses every level: each tmm sees a column inside
                # its own region, focuses it, and forwards the click down with
                # the column rebased. F12 cannot do this -- every tmm matches
                # it before forwarding, so it never reaches the one below.
                deep = COLS - 4
                os.write(ui_fd, f'\x1b[<0;{deep + 1};11M'.encode())
                os.write(ui_fd, f'\x1b[<0;{deep + 1};11m'.encode())
                pump(0.5)

            for level in (2, 3):
                focus_deepest()
                os.write(ui_fd, f'{BINARY} -S {socket} --shell --split {SPLIT}\r'
                         .encode())
                want = [i * (SPLIT + 1) for i in range(level)]
                assert until(lambda: sidebars() == want), \
                    (f'tmm nested {level} deep did not render', sidebars(), want,
                     repr(screen(ui_fd).line(0)))
            assert [i for i in range(COLS)
                    if screen(ui_fd).column(i) == '\u2502' * ROWS] == \
                [SPLIT, 2 * SPLIT + 1, 3 * SPLIT + 2], \
                ('nested dividers are not where the layout says',
                 [i for i in range(COLS)
                  if screen(ui_fd).column(i) == '\u2502' * ROWS])

            # Drawing is not enough: the innermost one has to be live. This
            # keystroke crosses terminal, tmm, tmm, tmm, shell, tmux.
            focus_deepest()
            assert screen(ui_fd).line(ROWS - 1).count('F12 sidebar') == 3, \
                ('a click did not focus every level',
                 repr(screen(ui_fd).line(ROWS - 1)))
            os.write(ui_fd, f'tmux -S {socket} new-session -d -s depth3\r'.encode())
            assert until(lambda: 'depth3' in tmux('list-sessions', '-F',
                                                  '#{session_name}'), limit=15), \
                'a command typed three levels down never reached the server'

            # Tear the nest down from the middle: a click on level 2's own
            # sidebar focuses it there, and q quits it. Level 3 lives on level
            # 2's pty, so it goes too, and level 1 gets its shell back.
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 6};11M'.encode())
            os.write(ui_fd, f'\x1b[<0;{SPLIT + 6};11m'.encode())
            pump(0.5)
            os.write(ui_fd, b'q')
            assert until(lambda: sidebars() == [0]), \
                ('the nested tmms did not exit', sidebars())
            os.write(ui_fd, b"echo rgn-unnested\r")
            assert until(lambda: any('rgn-unnested' in line for line in
                                     screen(ui_fd).region(SPLIT + 1))), \
                'the region shell did not come back after unnesting'

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

            # ---- the mouse reaches the child ----------------------------
            # A click only means something to the program inside the region if
            # the region encodes it in the mode that program selected. tmux
            # with `mouse on` turns a click into a pane selection, so the
            # effect is visible on the server and does not depend on the blit.
            tmux('set', '-g', 'mouse', 'on')
            tmux('split-window', '-t', 'alpha', '-d')
            panes = tmux('list-panes', '-t', 'alpha', '-F',
                         '#{pane_id} #{pane_top} #{pane_bottom}').split('\n')
            panes = [p.split() for p in panes if p]
            assert len(panes) == 2, panes
            # Whichever pane the client is not on, so the click has to move it.
            start = region_client('#{pane_id}')
            other = next(p for p in panes if p[0] != start)
            # A row safely inside the target pane, in the region's own
            # coordinates, offset into the window and made one-based for SGR.
            row = int(other[1]) + 1
            col = SPLIT + 1 + 2
            os.write(ui_fd, f'\x1b[<0;{col + 1};{row + 1}M'.encode())
            os.write(ui_fd, f'\x1b[<0;{col + 1};{row + 1}m'.encode())
            moved = until(lambda: region_client('#{pane_id}') == other[0])
            assert moved, ('a click in the region did not reach the child',
                           start, other, region_client('#{pane_id}'))

            # Scrolling inside the region must go to the child, not scroll the
            # sidebar behind it. With `mouse on` tmux enters copy mode.
            os.write(ui_fd, f'\x1b[<64;{col + 1};{row + 1}M'.encode())
            assert until(lambda: region_client('#{pane_in_mode}') == '1'), \
                ('a wheel event in the region did not reach the child',
                 region_client('#{pane_in_mode}'))
            os.write(ui_fd, b'q')  # leave copy mode
            assert until(lambda: region_client('#{pane_in_mode}') == '0'), \
                'the child never left copy mode'

            # Put the client back on one pane so the resize assertion below
            # reads a plain layout.
            tmux('kill-pane', '-t', other[0])
            tmux('set', '-g', 'mouse', 'off')

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
