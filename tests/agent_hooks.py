#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""An agent hook reports its state and the sidebar shows it.

tests/sidebar_status.py proves the transport with a one-line `printf` as the
emitter. This proves the thing that actually has to work: the real scripts in
contrib/agent-status, driven by the JSON a Claude Code hook receives on stdin,
reaching the sidebar row for the pane the hook ran in.

Everything here is real except the agent. The hook JSON is synthesised,
because running Claude Code in the suite would make the tests depend on an
agent being installed, logged in, and willing to answer -- but the scripts
under test, the transport, the tmux hop, the parse and the draw are all the
shipping ones.

Why the hook cannot simply write to its own terminal, which is the whole
reason tmm-report.sh exists: a Claude Code command hook runs in its own
session with no controlling terminal, so `/dev/tty` cannot be opened, and its
stdout is captured by the agent rather than written to the screen. The
documented escape hatch, a `terminalSequence` field in the hook's JSON reply,
carries only a short allowlist of sequences -- window titles and desktop
notifications -- and not OSC 7501. Both were measured before this was
written. What a hook does inherit is `$TMUX` and `$TMUX_PANE`, so it can ask
tmux where its pane is and write there.

The hooks therefore run here the way they really run: detached into their own
session with no controlling terminal, so that a regression which reintroduces
a dependency on `/dev/tty` fails this test instead of passing it.

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
# Found rather than spelled out: a path to one checkout runs nowhere else.
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
HOOK = ROOT / 'contrib/agent-status/claude-status-hook.py'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')
    for path in (HOOK, ROOT / 'contrib/agent-status/tmm-report.sh'):
        if not path.exists():
            raise SystemExit('missing %s' % path)

    with tempfile.TemporaryDirectory(prefix='tmm-hooks-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            try:
                return subprocess.check_output([TMUX, '-S', socket, *args],
                                               stderr=subprocess.PIPE,
                                               timeout=5).decode()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return ''

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha',
             '-x', '80', '-y', '24')

        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execvp(str(BINARY), [str(BINARY), '-S', socket, '--panes',
                                    '--session', 'alpha', '--split', str(SPLIT)])
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

        def until(predicate, limit=12):
            deadline = time.monotonic() + limit
            while time.monotonic() < deadline:
                pump(0.3)
                if predicate():
                    return True
            return False

        def fire(pane, event, **fields):
            """Run the real hook the way Claude Code runs it.

            In its own session with no controlling terminal, with the hook
            JSON on stdin and nothing but `$TMUX`/`$TMUX_PANE` to find the
            pane with -- which is exactly the environment measured above.
            """
            payload = dict(hook_event_name=event, session_id='test-session',
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
            # A hook that fails is a hook that interrupts the agent.
            assert proc.returncode == 0, \
                ('the hook exited nonzero', event, proc.stderr[:400])
            return proc

        try:
            pump(3.0)
            pane = tmux('display-message', '-p', '-t', 'alpha',
                        '#{pane_id}').strip()
            assert pane, 'no pane to report from'

            # A turn starts. This is also the proof that the transport works
            # at all from a session with no controlling terminal.
            fire(pane, 'UserPromptSubmit', user_input='hello')
            assert until(lambda: any('●' in l for l in sidebar())), \
                ('a submitted prompt did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # A tool runs, and the row names it rather than inventing a
            # percentage, because nothing in a hook event knows one.
            fire(pane, 'PreToolUse', tool_name='Bash', tool_use_id='t1')
            assert until(lambda: any('Bash' in l for l in sidebar())), \
                ('the running tool was not named in the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # Waiting on a human. This is the state screen reading guesses
            # worst, and the one a hook knows for certain.
            fire(pane, 'PermissionRequest', tool_name='Bash', tool_use_id='t2')
            assert until(lambda: any('permission' in l for l in sidebar())), \
                ('a permission request did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # A notification carries its own kind, so the mapping has to read
            # the message and not just the event name.
            fire(pane, 'Notification', message='agent_completed')
            assert until(lambda: not any('permission' in l for l in sidebar())), \
                ('a completed notification did not replace the blocked state',
                 [l for l in sidebar() if l.strip()][-8:])

            # A turn that ended badly has no screen-detectable equivalent.
            fire(pane, 'StopFailure', error_type='rate_limit')
            assert until(lambda: any('✗' in l for l in sidebar())), \
                ('a failed turn did not reach the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # A subagent must never speak for the pane: its stop arriving
            # here would mark the whole pane finished while the main turn is
            # still working. Asserted by the error state surviving it.
            fire(pane, 'Stop', agent_id='sub-1')
            fire(pane, 'SubagentStop', agent_type='Explore')
            pump(1.5)
            assert any('✗' in l for l in sidebar()), \
                ('a subagent event overwrote the pane state',
                 [l for l in sidebar() if l.strip()][-8:])

            # The session goes away and so does the record.
            fire(pane, 'SessionEnd', reason='clear')
            assert until(lambda: not any('✗' in l for l in sidebar())), \
                ('a cleared record still showed in the sidebar',
                 [l for l in sidebar() if l.strip()][-8:])

            # Outside tmux the same hook config must do nothing at all,
            # since it is installed once and used everywhere.
            env = dict(os.environ)
            env.pop('TMUX', None)
            env.pop('TMUX_PANE', None)
            bare = subprocess.run(
                [sys.executable, str(HOOK)],
                input=json.dumps({'hook_event_name': 'Stop'}).encode(),
                env=env, start_new_session=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert bare.returncode == 0 and not bare.stdout.strip(), \
                ('the hook did something outside tmux', bare.stdout[:200],
                 bare.stderr[:200])

            print('ok: a Claude Code hook with no controlling terminal reported '
                  'working, a named tool, blocked on permission, done, error '
                  'and clear to the sidebar; subagent events were ignored and '
                  'nothing happened outside tmux')
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


if __name__ == '__main__':
    main()
