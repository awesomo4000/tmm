#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The focus key is whatever the user said it is, and nothing else.

src/focuskey.zig parses the spelling; this checks the parse is actually what
the running program matches on, in all three places it matches -- which is
the part a unit test cannot reach. A rebound tmm has to do two things, and
the second is the one that would go unnoticed: move focus on the new key,
and leave the old one alone. A key that still works after being replaced is
a literal that was missed.

`--focus-key` and `TMM_FOCUS_KEY` are both exercised, since the env var is
the one a person would actually set, and a bad spelling is checked to fail
before the terminal is touched: a usage error that has already entered the
alternate screen costs the window it was typed in.

Only disposable tmux sockets and directories under /tmp are mutated.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402
import keys  # noqa: E402

ROWS, COLS, SPLIT = 20, 100, 30
BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def run(socket, argv, env_extra=None):
    """tmm in split mode on its own pty, with the screen it draws."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ.pop('TMUX', None)
        os.environ.pop(keys.ENV_VAR, None)
        os.environ.update(env_extra or {})
        os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--shell',
                                '--split', str(SPLIT), *argv])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    return pid, fd, Screen(ROWS, COLS)


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    with tempfile.TemporaryDirectory(prefix='tmm-focus-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')
        subprocess.run([TMUX, '-S', socket, '-f', '/dev/null',
                        'new-session', '-d', '-s', 'alpha'],
                       capture_output=True, timeout=10)
        try:
            # The default, and a spelling of the same key that tmm must not
            # be reading from its own default: the env var is set to it.
            check(socket, [], {keys.ENV_VAR: keys.FOCUS_SPELLING},
                  keys.FOCUS_LABEL, keys.FOCUS, keys.ALT_FOCUS)
            # Rebound on the command line. The old key is now an ordinary
            # keystroke for the shell, so it must not move focus.
            check(socket, ['--focus-key', keys.ALT_FOCUS_SPELLING], {},
                  keys.ALT_FOCUS_LABEL, keys.ALT_FOCUS, keys.FOCUS)
            # The flag wins over the environment, which is the order anyone
            # who sets the env var in a profile depends on.
            check(socket, ['--focus-key', keys.ALT_FOCUS_SPELLING],
                  {keys.ENV_VAR: keys.FOCUS_SPELLING},
                  keys.ALT_FOCUS_LABEL, keys.ALT_FOCUS, keys.FOCUS)
            refused()
        finally:
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)
    print('ok: the focus key follows --focus-key and ' + keys.ENV_VAR +
          ', the key it replaces stops moving focus, and a bad spelling is '
          'refused before the terminal is touched')


def check(socket, argv, env, label, bound, unbound):
    """Launch tmm, then assert `bound` moves focus and `unbound` does not."""
    pid, fd, display = run(socket, argv, env)

    def pump(duration):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            for _ in select.select([fd], [], [], 0.02)[0]:
                try:
                    data = os.read(fd, 1 << 16)
                except OSError:
                    return
                display.feed(data)
                if b'\x1b[c' in data or b'\x1b[0c' in data:
                    os.write(fd, b'\x1b[?1;2c')
                if b'\x1b[5n' in data:
                    os.write(fd, b'\x1b[0n')

    def hint():
        return display.line(ROWS - 1)

    def until(predicate, limit=10):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            pump(0.3)
            if predicate():
                return True
        return False

    try:
        # Split mode starts on the region, so the hint offers the way back.
        assert until(lambda: f'{label} sidebar' in hint()), \
            (f'the status line never offered {label}', argv, env, repr(hint()))

        # The key tmm was not given goes to the shell. Nothing on screen says
        # so directly, so the assertion is that the hint did not change: a
        # sidebar-focused tmm says "<key> shell" instead.
        os.write(fd, unbound)
        pump(1.2)
        assert f'{label} sidebar' in hint(), \
            ('a key tmm was not given moved focus anyway', argv, env,
             repr(unbound), repr(hint()))

        # The key it was given moves focus, and moves it back.
        os.write(fd, bound)
        assert until(lambda: f'{label} shell' in hint()), \
            ('the focus key did not reach the sidebar', argv, env,
             repr(bound), repr(hint()))
        os.write(fd, bound)
        assert until(lambda: f'{label} sidebar' in hint()), \
            ('the focus key did not return to the region', argv, env,
             repr(bound), repr(hint()))

        # Quitting needs the sidebar, which is the one ergonomic consequence
        # of the startup focus: get there with the key under test.
        os.write(fd, bound)
        assert until(lambda: f'{label} shell' in hint()), \
            ('the focus key stopped working', argv, env, repr(hint()))
        os.write(fd, b'q')
        done, status = 0, 0
        deadline = time.monotonic() + 8
        while done == 0 and time.monotonic() < deadline:
            pump(0.2)
            done, status = os.waitpid(pid, os.WNOHANG)
        assert done == pid, ('tmm did not exit', argv, env)
        assert os.waitstatus_to_exitcode(status) == 0, \
            ('tmm exited badly', os.waitstatus_to_exitcode(status))
    finally:
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        os.close(fd)


def refused():
    """A spelling tmm cannot use fails as a usage error, not a crash.

    Checked on a plain pipe rather than a pty: the point is that this happens
    before the terminal is opened at all, so there is nothing to restore.
    """
    for spelling, expected in (('bogus', 'not a key tmm knows'),
                               ('q', 'needs ctrl, alt or super'),
                               ('hyperctrl+alt+g', 'not a modifier tmm knows')):
        done = subprocess.run([str(BINARY), '--focus-key', spelling, '--shell'],
                              capture_output=True, timeout=10)
        assert done.returncode != 0, ('tmm accepted ' + spelling, done.stdout)
        text = done.stderr.decode()
        assert spelling in text and expected in text, \
            ('the refusal did not say what was wrong', spelling, text)
        assert '\x1b[?1049h' not in done.stdout.decode(errors='replace'), \
            ('tmm entered the alternate screen before refusing', spelling)


if __name__ == '__main__':
    main()
