#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""`--panes` refuses the one session it cannot composite, and only that one.

Compositing the session tmm is running in collapses it. tmm sizes the session
with `refresh-client -C`, tmux re-tiles it, and the window being re-tiled
holds tmm's own pane, so tmm shrinks and then sizes down again. Measured from
a 200-column pane before this was caught: 200, 132, 81, 30, then 4 columns
and stuck at the floor, with no region drawn at all. It reads as tmm being
broken rather than aimed at the wrong session.

Nothing covered this because every other panes harness launches tmm with
`$TMUX` popped, so tmm was never a child of a pane the way it actually is
when someone runs it.

The second half is what keeps the check honest. Pane ids are per-server, so
`%3` exists on every server and a `$TMUX_PANE` from another server would
resolve here and name an innocent session. So the server is identified too,
by asking both ends for `#{socket_path}`, which tmux normalises -- a server
addressed through `/private/tmp` still reports `/tmp`. The cross-server case
below is that guard, and it must keep working.

Only disposable tmux sockets, processes, and files under /tmp are mutated.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    if not BINARY.exists():
        raise SystemExit('build first: zig build')

    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-nested-', dir='/tmp') as root:
        near = os.path.join(root, 'near')
        far = os.path.join(root, 'far')

        def tmux(socket, *args, check=False):
            r = subprocess.run([TMUX, '-S', socket, *args],
                               capture_output=True, text=True, timeout=15)
            if check:
                assert r.returncode == 0, (args, r.stderr)
            return r.stdout

        # The server tmm will be launched from, with a wide pane so a collapse
        # is unmistakable, plus a second session worth compositing.
        tmux(near, '-f', '/dev/null', 'new-session', '-d', '-s', 'host',
             '-x', '200', '-y', '50', check=True)
        tmux(near, 'new-session', '-d', '-s', 'work', '-x', '100', '-y', '30',
             check=True)
        tmux(near, 'split-window', '-h', '-t', 'work', check=True)
        tmux(near, 'send-keys', '-t', 'work', 'echo HELLOPANE', 'Enter')
        # A different server entirely, for the cross-server guard.
        tmux(far, '-f', '/dev/null', 'new-session', '-d', '-s', 'faraway',
             '-x', '100', '-y', '30', check=True)
        tmux(far, 'send-keys', '-t', 'faraway', 'echo FARPANE', 'Enter')
        time.sleep(1.0)

        def launch(argv, settle=6.0):
            """Run tmm inside a real pane of `near`, and read that pane back."""
            tmux(near, 'send-keys', '-t', 'host', 'clear', 'Enter')
            time.sleep(0.4)
            cmd = '%s %s' % (BINARY, ' '.join(argv))
            tmux(near, 'send-keys', '-t', 'host', cmd, 'Enter')
            time.sleep(settle)
            shown = tmux(near, 'capture-pane', '-p', '-t', 'host')
            width = tmux(near, 'display-message', '-p', '-t', 'host',
                         '#{pane_width}').strip()
            # Leave the pane idle for the next case whatever happened.
            tmux(near, 'send-keys', '-t', 'host', 'q')
            time.sleep(0.6)
            tmux(near, 'send-keys', '-t', 'host', 'C-c')
            time.sleep(0.4)
            return shown, int(width or 0)

        # 1. The failing case: no --session, so tmm would take the session it
        #    is sitting in. It has to say so instead.
        shown, width = launch(['-S', near, '--panes'])
        if 'cannot composite' not in shown:
            failures.append('a nested --panes did not explain itself: %r'
                            % shown.strip()[-200:])
        if '"host"' not in shown:
            failures.append('the message did not name the session: %r'
                            % shown.strip()[-200:])
        if '--session work' not in shown:
            failures.append('the message did not offer the other session: %r'
                            % shown.strip()[-200:])
        if width < 100:
            failures.append('the host pane was resized anyway (%d columns), '
                            'so the check ran too late' % width)

        # 2. The same session, asked for by name. Still refused, since naming
        #    it does not make it work.
        shown, _ = launch(['-S', near, '--panes', '--session', 'host'])
        if 'cannot composite' not in shown:
            failures.append('--session naming the host session was accepted: '
                            '%r' % shown.strip()[-200:])

        # 3. Another session on the same server: this is the working case,
        #    and the refusal must not reach it.
        shown, width = launch(['-S', near, '--panes', '--session', 'work'])
        if 'cannot composite' in shown:
            failures.append('a different session was refused: %r'
                            % shown.strip()[-200:])
        if 'HELLOPANE' not in shown:
            failures.append('the composited session did not draw: %r'
                            % shown.strip()[-300:])

        # 4. A different server. `$TMUX_PANE` still names a pane that exists
        #    here, so a check that looked only at the pane id would refuse
        #    this wrongly.
        shown, width = launch(['-S', far, '--panes'])
        if 'cannot composite' in shown:
            failures.append('a session on another server was refused: the '
                            'pane id was trusted without the socket: %r'
                            % shown.strip()[-200:])
        if 'FARPANE' not in shown:
            failures.append('the other server did not draw: %r'
                            % shown.strip()[-300:])

        for socket in (near, far):
            subprocess.run([TMUX, '-S', socket, 'kill-server'],
                           capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: --panes refuses the session it is running in, names the ones '
          'it could use instead, and still composites another session and '
          'another server')


if __name__ == '__main__':
    main()
