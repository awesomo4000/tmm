#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A reported state reaches the sidebar with no compositor running.

tests/agent_hooks.py covers `--panes`, where tmm runs a terminal per pane and
parses OSC 7501 out of the pane's own bytes. That is the minority of how tmm
is used: it is a view over tmux, and in sidebar-only and `--shell` mode it
talks to tmux over control mode and never sees pane output at all. The
in-band route therefore reaches nothing in those modes, and `%output` on a
control stream only covers the session that client is attached to anyway --
both measured, both recorded in src/reported.zig.

So a reporter also writes the record to the `@tmm_status` pane option, which
tmm reads for every pane on the server in the `list-panes -a` query it
already makes. This asserts that path, in the two modes the other test does
not cover, and across two sessions -- because covering one session is exactly
what the in-band route could have managed.

What this does NOT change is the heuristic. Screen detection still runs and
still decides every pane that reported nothing; the last case here is the
proof, a pane with no report at all keeping the inferred indicator.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402

ROWS, COLS, SPLIT = 44, 170, 34
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
HOOK = ROOT / 'contrib/agent-status/claude-status-hook.py'
TMUX = shutil.which('tmux') or 'tmux'


def run_mode(argv, label):
    """Drive tmm in one mode and assert reports reach its sidebar."""
    with tempfile.TemporaryDirectory(prefix='tmm-hooksb-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        # Two sessions. The second is the one the in-band route could never
        # have reported on, since a control client hears output from the
        # session it is attached to and no other.
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24')
        tmux('new-session', '-d', '-s', 'beta', '-x', '80', '-y', '24')

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket] + argv)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

        display = Screen(ROWS, COLS)

        def pump(duration):
            until_ = time.monotonic() + duration
            while time.monotonic() < until_:
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

        def sidebar():
            return [line[:SPLIT] for line in display.lines()]

        def until(predicate, limit=15):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def fire(pane, event, **fields):
            """The real hook, detached, as Claude Code runs it."""
            payload = dict(hook_event_name=event, session_id='sb-%s' % pane,
                           **fields)
            env = dict(os.environ)
            env['TMUX'] = '%s,0,0' % socket
            env['TMUX_PANE'] = pane
            env['TMM_REPORT_TMUX'] = TMUX
            proc = subprocess.run(
                [sys.executable, str(HOOK)],
                input=json.dumps(payload).encode(),
                env=env, start_new_session=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert proc.returncode == 0, \
                ('the hook exited nonzero', event, proc.stderr[:400])

        try:
            pump(3.0)
            pane_a = tmux('display-message', '-p', '-t', 'alpha',
                          '#{pane_id}').strip()
            pane_b = tmux('display-message', '-p', '-t', 'beta',
                          '#{pane_id}').strip()
            assert pane_a and pane_b, 'no panes to report from'

            # The hook never touched a terminal: in this mode there is no
            # terminal of tmm's to touch. The option carried it.
            fire(pane_a, 'UserPromptSubmit', user_input='hi')
            assert until(lambda: any('●' in l for l in sidebar())), \
                ('%s: a report did not reach the sidebar without a compositor'
                 % label, [l for l in sidebar() if l.strip()][-12:])

            # The option really is what carried it, not a coincidence.
            stored = tmux('show', '-p', '-t', pane_a, '@tmm_status')
            assert 'state=working' in stored, \
                ('%s: the pane option was not set' % label, stored)

            # A session the in-band route could not have covered.
            fire(pane_b, 'PermissionRequest', tool_name='Bash',
                 tool_use_id='t1')
            assert until(lambda: any('permission' in l for l in sidebar())), \
                ('%s: a report from a second session did not arrive' % label,
                 [l for l in sidebar() if l.strip()][-12:])

            # error has no screen-detectable equivalent, which is the reason
            # the whole payload rides the option rather than a state word.
            fire(pane_a, 'StopFailure', error_type='rate_limit')
            assert until(lambda: any('✗' in l for l in sidebar())), \
                ('%s: an error report did not arrive' % label,
                 [l for l in sidebar() if l.strip()][-12:])

            # Clearing unsets the option rather than leaving a stale state.
            fire(pane_a, 'SessionEnd', reason='clear')
            assert until(lambda: not any('✗' in l for l in sidebar())), \
                ('%s: a cleared record still showed' % label,
                 [l for l in sidebar() if l.strip()][-12:])
            left = tmux('show', '-p', '-t', pane_a, '@tmm_status')
            assert 'state=' not in left, \
                ('%s: the option outlived the record' % label, left)

            # And the heuristic still owns every pane that said nothing: this
            # pane never reported, and its row is still drawn from what tmm
            # worked out by itself.
            rows = [l for l in sidebar() if l.strip()]
            assert any('bash' in l or 'shell' in l for l in rows), \
                ('%s: a pane that reported nothing lost its inferred row'
                 % label, rows[-12:])
            print('ok (%s): a reported state reached the sidebar with no '
                  'compositor, in two sessions, and a pane that reported '
                  'nothing kept its inferred row' % label)
        finally:
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


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    # Pure sidebar mode: no terminal of tmm's own anywhere.
    run_mode([], 'sidebar')
    # And split mode, where tmm has a region but it is a shell on tmm's own
    # pty rather than a tmux pane, so the panes are still only reachable
    # through tmux.
    run_mode(['--shell', '--split', str(SPLIT)], '--shell')


if __name__ == '__main__':
    main()
