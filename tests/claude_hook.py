#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The Claude Code hook leaves the record a real session would expect.

The hook's whole output is the `@tmm_status` pane option, so this asserts that
value after each event, with payloads shaped as Claude Code sends them. That
last part is the point. A Notification carries its type in
`notification_type` and the text a person reads in `message`; the hook used to
key on `message`, and the test that covered it fed the type code in `message`,
so both shared the wrong assumption and the mapping never fired for real.

The rest are the transitions a turn actually makes: approving a permission
quickly, which used to leave `!` showing because the only way off blocked was
a PreToolUse the rate limiter could drop; a turn ending as `done` and staying
so through a late idle_prompt; and tool events that fire on every call
changing nothing unless the pane was blocked.

Only disposable tmux sockets and files under /tmp are mutated. The hook keeps
its per-session state in TMPDIR, which is pointed at the test's own
directory.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'contrib/agent-status/claude-status-hook.py'
TMUX = shutil.which('tmux') or 'tmux'


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-hook-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            r = subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                               text=True, timeout=5)
            return r.stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'work', '-x', '80', '-y', '24')
        pane = tmux('display-message', '-p', '-t', 'work', '#{pane_id}').strip()
        assert pane, 'no pane'

        def fire(event, session='s1', **fields):
            """The real hook, detached and without a terminal, as Claude Code runs it."""
            env = dict(os.environ, TMUX='%s,0,0' % socket, TMUX_PANE=pane,
                       TMM_REPORT_TMUX=TMUX, TMPDIR=root)
            payload = dict(hook_event_name=event, session_id=session, **fields)
            proc = subprocess.run([sys.executable, str(HOOK)],
                                  input=json.dumps(payload).encode(), env=env,
                                  start_new_session=True, capture_output=True,
                                  timeout=10)
            if proc.returncode != 0:
                failures.append('%s: the hook exited %d' % (event, proc.returncode))

        def record():
            return tmux('show', '-pv', '-t', pane, '@tmm_status').strip()

        def expect(label, *parts):
            got = record()
            fields = dict(p.split('=', 1) for p in got.split(':') if '=' in p)
            for part in parts:
                key, value = part.split('=', 1)
                if fields.get(key) != value:
                    failures.append('%s: wanted %s, record is %r' % (label, part, got))
                    return

        # A turn starts and a tool runs.
        fire('UserPromptSubmit', prompt='go')
        expect('prompt', 'state=working')
        fire('PreToolUse', tool_name='Bash', tool_input={})
        expect('tool', 'state=working')

        # A permission prompt, approved at once: the PostToolUse comes well
        # inside the rate limiter's second, and has to end the block anyway.
        fire('PermissionRequest', tool_name='Bash', tool_input={})
        expect('permission asked', 'state=blocked', 'kind=permission')
        fire('PostToolUse', tool_name='Bash', tool_input={}, tool_response={})
        expect('permission answered', 'state=working')

        # The next PreToolUse out of a block gets through even inside the
        # rate limit's window.
        fire('PermissionRequest', tool_name='Edit', tool_input={})
        fire('PreToolUse', tool_name='Read', tool_input={})
        expect('next tool after a block', 'state=working')

        # A tool event while merely working changes nothing: these fire on
        # every call, and the record keeps the tool name it had.
        before = record()
        fire('PostToolUse', tool_name='Read', tool_input={}, tool_response={})
        if record() != before:
            failures.append('a PostToolUse while working rewrote the record: '
                            '%r -> %r' % (before, record()))

        # A Notification shaped as Claude Code sends it: the code in
        # notification_type, prose in message. From working, so a hook that
        # ignored the notification would leave working and fail here rather
        # than pass on the block an earlier event left behind.
        fire('UserPromptSubmit', prompt='continue')
        expect('back to work', 'state=working')
        fire('Notification', notification_type='permission_prompt',
             message='Claude needs your permission to use Bash')
        expect('permission notification', 'state=blocked', 'kind=permission')
        fire('Notification', notification_type='agent_needs_input',
             message='Claude needs your input')
        expect('needs-input notification', 'state=blocked', 'kind=question')
        # A type that is not a state change reports nothing.
        held = record()
        fire('Notification', notification_type='auth_success', message='Logged in')
        if record() != held:
            failures.append('auth_success changed the record: %r' % record())

        # The turn ends: done, and a late idle_prompt does not undo it.
        fire('Stop', stop_hook_active=False)
        expect('turn ended', 'state=done')
        fire('Notification', notification_type='idle_prompt',
             message='Claude is waiting for your input')
        expect('idle prompt after the turn ended', 'state=done')

        # A release old enough to send no type is read from its message, for
        # the messages it is known to send, and only while working.
        fire('UserPromptSubmit', session='s2', prompt='again')
        fire('Notification', session='s2', message='Claude is waiting for your input')
        expect('legacy idle message', 'state=idle')
        fire('Notification', session='s2', message='Something unrelated happened')
        expect('legacy unknown message', 'state=idle')

        # A subagent never speaks for the pane.
        fire('UserPromptSubmit', session='s3', prompt='x')
        fire('Stop', session='s3', agent_id='sub-1')
        expect('subagent stop', 'state=working')

        # The session ends and the record goes.
        fire('SessionEnd', session='s3', reason='exit')
        if record():
            failures.append('SessionEnd left a record: %r' % record())

        subprocess.run([TMUX, '-S', socket, 'kill-server'], capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: the hook maps real payloads, ends a block on the answer even '
          'inside the rate limit, ends a turn as done, and stays quiet otherwise')


if __name__ == '__main__':
    main()
