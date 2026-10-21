#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The tmux prefix works in compositor mode, and only the prefix does.

tmm's input path is `send-keys -H`: raw bytes into the pane's program, which
is what carries the kitty keyboard protocol through a tmux that cannot speak
it. The cost was that tmux never saw those keys as *client* input, so none of
its own bindings fired -- `C-a h` reached the shell as a 0x01 byte and an `h`
rather than selecting the pane to the left.

`send-keys -K` is the way back. It is documented as sending a key to the
target client "so they are looked up in the client's key table", and a
control-mode client has a real key table like any other. So tmm spells the
key the way tmux does and hands it over; tmux owns the tables, the prefix
state and the commands, and a binding changed in .tmux.conf needs nothing in
tmm. That is what this asserts, through the binary, against a real tmux.

The second half matters as much as the first. Only two presses may take that
route -- the prefix, and the key after it -- because everything else has to
stay on the byte path. A plain `h` typed into a shell must arrive as `h`, and
a prefix sequence must not leave its bytes behind in the pane as well.

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
    """Reply to the queries vaxis makes, so it never waits on the harness."""
    if re.search(rb'\x1b\[[0-9]*c', data):
        os.write(fd, b'\x1b[?62;4c')
    if b'\x1b[5n' in data:
        os.write(fd, b'\x1b[0n')
    if b'\x1b[6n' in data:
        os.write(fd, b'\x1b[1;1R')
    if b'\x1b[?u' in data:
        os.write(fd, b'\x1b[?0u')


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')

    with tempfile.TemporaryDirectory(prefix='tmm-prefix-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')
        marker = os.path.join(root, 'ranbinding')

        def tmux(*args, check=False):
            r = subprocess.run([TMUX, '-S', socket, *args],
                               capture_output=True, text=True, timeout=10)
            if check:
                assert r.returncode == 0, (args, r.stderr)
            return r.stdout

        # A deliberately non-default prefix, so a pass cannot come from tmm
        # having `C-b` baked in somewhere: it has to have asked the server.
        conf = os.path.join(root, 'conf')
        with open(conf, 'w') as f:
            f.write('set -g prefix C-a\n'
                    'set -g prefix2 None\n'
                    'bind -T prefix h select-pane -L\n'
                    'bind -T prefix l select-pane -R\n'
                    # A binding whose effect is visible from outside tmux
                    # altogether, to prove the command really ran.
                    'bind -T prefix e run-shell "echo ran > %s"\n' % marker)

        tmux('-f', conf, 'new-session', '-d', '-s', 'p', '-x', '100', '-y', '30',
             check=True)
        tmux('split-window', '-h', '-t', 'p', check=True)
        panes = tmux('list-panes', '-t', 'p', '-F', '#{pane_id}').split()
        assert len(panes) == 2, panes
        left, right = panes
        tmux('select-pane', '-t', right, check=True)
        assert tmux('display-message', '-p', '-t', 'p', '#{pane_id}').strip() == right

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
            return tmux('display-message', '-p', '-t', 'p', '#{pane_id}').strip()

        def press(*chunks):
            for b in chunks:
                os.write(fd, b)
                pump(0.35)

        def until(predicate, limit=8):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.25)
                if predicate():
                    return True
            return False

        failures = []

        def start_at(pane):
            """Pin the active pane before a directional assertion.

            `select-pane -L` and `-R` wrap, so from an end pane they land on
            the far side rather than staying put. Asserting a direction
            without fixing the starting pane first reads a wrap as a failure
            -- or worse, reads it as a pass.
            """
            tmux('select-pane', '-t', pane, check=True)
            pump(0.4)

        try:
            pump(3.0)
            # tmm starts focused on the sidebar; ctrl+` moves the keyboard to
            # the region, which is where keys are forwarded at all.
            press(b'\x00')
            pump(0.5)

            # 1. The prefix tmm had to ask the server for, then a bound key.
            #    tmux reports the new active pane as %window-pane-changed,
            #    which the compositor already follows, so this also proves
            #    tmm's own focus lands on the pane tmux selected.
            start_at(right)
            press(b'\x01', b'h')
            if not until(lambda: active() == left):
                failures.append('C-a h did not select the left pane (active %s)'
                                % active())

            # 2. And back, so it is not a one-way accident.
            start_at(left)
            press(b'\x01', b'l')
            if not until(lambda: active() == right):
                failures.append('C-a l did not select the right pane (active %s)'
                                % active())

            # 3. A binding whose effect is outside tmux entirely: the command
            #    ran, rather than tmux merely changing its key table.
            press(b'\x01', b'e')
            if not until(lambda: os.path.exists(marker)):
                failures.append('C-a e did not run the bound command')

            # 4. The half that is easy to break: an ordinary key still goes to
            #    the pane as a byte. Typed into the shell, it has to come back
            #    on the pane's own screen.
            tmux('send-keys', '-t', right, 'C-u')
            pump(0.4)
            press(b'z', b'z', b'z')

            def typed():
                return 'zzz' in tmux('capture-pane', '-p', '-t', right)
            if not until(typed):
                failures.append('a plain key did not reach the pane as a byte')

            # 5. And a prefix sequence leaves nothing behind in the pane. If
            #    the prefix or the key after it also went down the byte path,
            #    the shell would have them on its line.
            tmux('send-keys', '-t', right, 'C-u')
            pump(0.4)
            press(b'\x01', b'l')
            pump(0.8)
            line = tmux('capture-pane', '-p', '-t', right)
            if 'l' in line.split('$')[-1]:
                failures.append('a prefix sequence left bytes in the pane: %r'
                                % line.split('$')[-1][:40])

            # 6. An unbound key after the prefix is dropped, not typed. tmux
            #    drops it too, so the pane must not receive it either.
            tmux('send-keys', '-t', right, 'C-u')
            pump(0.4)
            press(b'\x01', b'\x1b[24~')   # F12, bound to nothing here
            pump(0.8)
            tail = tmux('capture-pane', '-p', '-t', right).split('$')[-1]
            if tail.strip():
                failures.append('an unbound prefix key reached the pane: %r'
                                % tail[:40])

            # 7. The prefix still works after all that, so the local notion of
            #    "are we after the prefix" did not drift out of step with
            #    tmux's own key table.
            start_at(right)
            before = active()
            press(b'\x01', b'h')
            if not until(lambda: active() == left):
                failures.append('the prefix stopped working after a dropped key '
                                '(was %s, now %s, pane tail %r)'
                                % (before, active(),
                                   tmux('capture-pane', '-p', '-t', right)
                                   .split('$')[-1][:40]))
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
        print('ok: the configured tmux prefix runs tmux bindings, and only '
              'the prefix sequence leaves the byte path')


if __name__ == '__main__':
    main()
