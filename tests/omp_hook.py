#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The omp extension leaves the record a real omp session would expect.

omp hooks are extensions loaded into its own process, so this loads
contrib/agent-status/omp-status.ts the same way, under bun, and drives it with
a stand-in for omp's extension API. The events and their order are what omp
18.16 sent from a tmux pane, recorded with every event logged:

- An approval: agent_start, tool_execution_start, tool_approval_requested
  while the prompt is up, tool_approval_resolved, then agent_end. A denial
  resolves the same way with approved false, and the turn goes on.
- The ask tool: tool_execution_start with toolName "ask" while the question
  is up, tool_execution_end once answered.
- Escape: agent_end whose last assistant message stopped "aborted".
- An error: agent_end stopped "error", then auto_retry_start, a fresh
  agent_start, and auto_retry_end with success false when it gives up.
- A session with no UI, as a subagent runs, reports nothing.
- session_shutdown clears the record, and has finished doing so by the time
  its handler settles, which is when omp exits.

Every report says app=omp.

Only disposable tmux sockets and files under /tmp are mutated.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / 'contrib/agent-status/omp-status.ts'
TMUX = shutil.which('tmux') or 'tmux'
BUN = shutil.which('bun') or os.path.expanduser('~/.bun/bin/bun')


def b64(text):
    return base64.b64encode(text.encode()).decode()


# Reads one event per line, as JSON, and answers each with a line once its
# handlers have settled: {"on": name, "event": {...}, "ui": bool}.
DRIVER = r'''
import readline from "node:readline";
const handlers = {};
const pi = { on(name, fn) { (handlers[name] ??= []).push(fn); }, events: { on() {} } };
const mod = await import(process.argv[2]);
mod.default(pi);
const lines = readline.createInterface({ input: process.stdin });
for await (const line of lines) {
  const step = JSON.parse(line);
  const ctx = { hasUI: step.ui !== false };
  for (const fn of handlers[step.on] ?? []) await fn({ type: step.on, ...step.event }, ctx);
  process.stdout.write("ok\n");
  if (step.on === "session_shutdown") process.exit(0);
}
'''


def assistant(stop, error=None):
    message = {'role': 'assistant', 'stopReason': stop, 'content': []}
    if error:
        message['errorMessage'] = error
    return {'messages': [{'role': 'user', 'content': []}, message]}


def main():
    if not Path(BUN).exists():
        print('skip: no bun, which omp extensions run on')
        return
    failures = []
    with tempfile.TemporaryDirectory(prefix='tmm-omp-hook-', dir='/tmp') as root:
        socket = os.path.join(root, 'socket')
        driver_path = os.path.join(root, 'driver.mjs')
        with open(driver_path, 'w') as f:
            f.write(DRIVER)

        def tmux(*args):
            return subprocess.run([TMUX, '-S', socket, *args], capture_output=True,
                                  text=True, timeout=5).stdout

        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'work', '-x', '80', '-y', '24')
        pane = tmux('display-message', '-p', '-t', 'work', '#{pane_id}').strip()
        assert pane, 'no pane'

        env = dict(os.environ, TMUX='%s,0,0' % socket, TMUX_PANE=pane,
                   TMM_REPORT_TMUX=TMUX)
        proc = subprocess.Popen([BUN, driver_path, str(EXTENSION)], env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                text=True)

        def fire(name, ui=True, **event):
            proc.stdin.write(json.dumps({'on': name, 'event': event, 'ui': ui}) + '\n')
            proc.stdin.flush()
            if proc.stdout.readline().strip() != 'ok':
                failures.append('%s: the driver did not answer' % name)

        def record():
            return tmux('show', '-pv', '-t', pane, '@tmm_status').strip()

        def fields():
            return dict(p.split('=', 1) for p in record().split(':') if '=' in p)

        def expect(label, *parts, settle=3.0):
            """Wait for the record to hold every part: reports run in the
            background of the handler, as they do inside omp."""
            wanted = dict(p.split('=', 1) for p in parts)
            deadline = time.monotonic() + settle
            while time.monotonic() < deadline:
                got = fields()
                if all(got.get(k) == v for k, v in wanted.items()):
                    return
                time.sleep(0.03)
            failures.append('%s: wanted %s, record is %r' % (label, ' '.join(parts), record()))

        def unchanged(label):
            before = record()
            time.sleep(0.4)
            if record() != before:
                failures.append('%s: the record changed: %r -> %r' % (label, before, record()))

        try:
            fire('session_start')
            time.sleep(0.3)
            if record():
                failures.append('session_start reported something: %r' % record())

            # An approval, granted.
            fire('agent_start')
            expect('turn started', 'state=working', 'app=omp')
            fire('tool_execution_start', toolName='bash')
            expect('tool', 'state=working', 'title=' + b64('bash'))
            fire('tool_approval_requested', toolName='bash', approvalMode='always-ask')
            expect('approval asked', 'state=blocked', 'kind=permission',
                   'title=' + b64('bash'), 'app=omp')
            fire('tool_approval_resolved', toolName='bash', approved=True)
            expect('approved', 'state=working')
            fire('tool_execution_end', toolName='bash', isError=False)
            fire('agent_end', **assistant('stop'))
            expect('turn ended', 'state=done', 'app=omp')

            # Denied: the turn goes on, the model answers.
            fire('agent_start')
            fire('tool_execution_start', toolName='bash')
            fire('tool_approval_requested', toolName='bash', approvalMode='always-ask')
            expect('approval asked again', 'state=blocked', 'kind=permission')
            fire('tool_approval_resolved', toolName='bash', approved=False,
                 reason='denied by user')
            expect('denied', 'state=working')
            fire('tool_execution_end', toolName='bash', isError=True)
            fire('agent_end', **assistant('stop'))
            expect('denied turn ended', 'state=done')

            # The ask tool.
            fire('agent_start')
            fire('tool_execution_start', toolName='ask')
            expect('question asked', 'state=blocked', 'kind=question', 'app=omp')
            fire('tool_execution_end', toolName='ask', isError=False)
            expect('question answered', 'state=working')
            fire('agent_end', **assistant('stop'))
            expect('question turn ended', 'state=done')

            # Two prompts up at once: answering one is still blocked.
            fire('agent_start')
            fire('tool_approval_requested', toolName='bash')
            fire('tool_approval_requested', toolName='edit')
            fire('tool_approval_resolved', toolName='bash', approved=True)
            expect('one of two answered', 'state=blocked')
            fire('tool_approval_resolved', toolName='edit', approved=True)
            expect('both answered', 'state=working')

            # Tool calls in a burst are collapsed while working. The pause puts
            # the first one outside the window of the last tool reported.
            time.sleep(1.1)
            fire('tool_execution_start', toolName='read')
            expect('first of a burst', 'state=working', 'title=' + b64('read'))
            fire('tool_execution_start', toolName='grep')
            unchanged('a second tool inside the window')

            # Escape.
            fire('agent_end', **assistant('aborted', 'Interrupted by user'))
            expect('escaped', 'state=idle', 'app=omp')

            # An error, retried, and given up on.
            fire('agent_start')
            fire('agent_end', **assistant('error', '503 service unavailable'))
            expect('error', 'state=error', 'msg=' + b64('503 service unavailable'))
            fire('auto_retry_start', attempt=1, maxAttempts=3, delayMs=1000,
                 errorMessage='503 service unavailable')
            expect('retrying', 'state=working')
            fire('agent_start')
            fire('agent_end', **assistant('error', '503 service unavailable'))
            fire('auto_retry_end', success=False, attempt=3,
                 finalError='503 service unavailable')
            expect('gave up', 'state=error', 'app=omp')

            # A session without a UI is a subagent: nothing it does reports.
            fire('agent_start')
            expect('main turn', 'state=working')
            fire('agent_start', ui=False)
            fire('tool_approval_requested', ui=False, toolName='bash')
            fire('agent_end', ui=False, **assistant('stop'))
            unchanged('a subagent')

            # Shutdown: cleared before the handler settles, so before omp exits.
            fire('agent_end', **assistant('stop'))
            fire('session_shutdown')
            if record():
                failures.append('session_shutdown left a record: %r' % record())
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            subprocess.run([TMUX, '-S', socket, 'kill-server'], capture_output=True, timeout=10)

    if failures:
        for f in failures:
            print('FAIL: %s' % f, file=sys.stderr)
        raise SystemExit(1)
    print('ok: omp events go working, blocked while a prompt or question is up, done '
          'at the end of a turn, idle on Escape, error when a retry gives up, and '
          'clear at shutdown')


if __name__ == '__main__':
    main()
