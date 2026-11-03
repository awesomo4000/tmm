#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The hook leaves the record a real Codex session would expect.

The payloads and their order are what Codex 0.166 sent its hooks from a tmux
pane, recorded, not what its documentation suggests:

- An approval. Codex runs a command in its sandbox first, so a PostToolUse
  carrying the sandbox's refusal arrives before it asks; then PreToolUse
  again, PermissionRequest while the prompt is on screen, and PostToolUse once
  it is approved. The pane goes working, blocked, working, and the refusal
  changes nothing.
- The turn ends with Stop: done.
- Escape mid-turn sends Interrupt and no Stop. That is idle, not working
  forever and not done.
- SessionEnd takes the record away.

Every report says app=codex, from the argument the Codex hooks pass.

Only disposable tmux sockets and files under /tmp are mutated. The hook keeps
its per-session state in TMPDIR, which is pointed at the test's own
directory.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'contrib/agent-status/agent-status-hook.py'
TMUX = shutil.which('tmux') or 'tmux'
SESSION = '01a1a103-e93b-72e2-b124-96774e342c0d'
TURN = '01a1a103-eb5d-7e72-8df9-10d66091e95c'
COMMAND = {'command': 'echo hi > /tmp/made.txt'}
# The record carries text fields base64-encoded.
BASH = 'title=' + base64.b64encode(b'Bash').decode()


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-codex-hook-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')

        def tmux(*args):
            r = subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                               text=True, timeout=5)
            return r.stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'work', '-x', '80', '-y', '24')
        pane = tmux('display-message', '-p', '-t', 'work', '#{pane_id}').strip()
        assert pane, 'no pane'

        def fire(event, turn=True, **fields):
            """The real hook, detached and without a terminal, as Codex runs it."""
            env = dict(os.environ, TMUX='%s,0,0' % socket, TMUX_PANE=pane,
                       TMM_REPORT_TMUX=TMUX, TMPDIR=root)
            payload = dict(session_id=SESSION, transcript_path=root + '/rollout.jsonl',
                           cwd=root, hook_event_name=event, model='gpt',
                           permission_mode='default', **fields)
            if turn:
                payload['turn_id'] = TURN
            proc = subprocess.run([sys.executable, str(HOOK), 'codex'],
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

        fire('SessionStart', turn=False, source='startup')
        if record():
            failures.append('SessionStart reported something: %r' % record())

        fire('UserPromptSubmit', prompt='make the file')
        expect('prompt', 'state=working', 'app=codex')
        fire('PreToolUse', tool_name='Bash', tool_input=COMMAND,
             tool_use_id='exec-1')
        expect('tool', 'state=working', BASH)
        before = record()
        fire('PostToolUse', tool_name='Bash', tool_input=COMMAND,
             tool_response='bash: /tmp/made.txt: Operation not permitted\n',
             tool_use_id='exec-1')
        if record() != before:
            failures.append('the sandbox refusal rewrote the record: %r -> %r'
                            % (before, record()))
        fire('PreToolUse', tool_name='Bash', tool_input=COMMAND,
             tool_use_id='exec-2')
        fire('PermissionRequest', tool_name='Bash',
             tool_input=dict(COMMAND, description='May I run this outside the sandbox?'))
        expect('approval asked', 'state=blocked', 'kind=permission', BASH,
               'app=codex')
        fire('PostToolUse', tool_name='Bash', tool_input=COMMAND, tool_response='',
             tool_use_id='exec-2')
        expect('approved', 'state=working')
        fire('Stop', stop_hook_active=False, last_assistant_message='done')
        expect('turn ended', 'state=done', 'app=codex')

        fire('UserPromptSubmit', prompt='sleep 60')
        fire('PreToolUse', tool_name='Bash', tool_input={'command': 'sleep 60'},
             tool_use_id='exec-3')
        fire('Interrupt')
        expect('interrupted', 'state=idle', 'app=codex')

        fire('SessionEnd', turn=False, reason='other')
        if record():
            failures.append('SessionEnd left a record: %r' % record())

        subprocess.run([TMUX, '-S', socket, 'kill-server'], capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: Codex payloads go working, blocked while asking, working once '
          'approved, done at Stop, idle on Interrupt, and clear at SessionEnd')


if __name__ == '__main__':
    main()
