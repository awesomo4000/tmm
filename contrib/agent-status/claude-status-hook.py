#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Map a Claude Code hook event onto one OSC 7501 report.

Installed once for every event in settings-snippet.json; the event name
arrives in the JSON on stdin, so one script covers all of them and there is
one place where the mapping lives.

The transport is tmm-report.sh beside this file, which writes to the pane tty.
A hook cannot write to the terminal itself: it runs in its own session with no
controlling terminal, and its stdout goes to the agent rather than the screen.
See that script for the whole story.

The mapping:

    UserPromptSubmit                     working   a turn started
    PreToolUse                           working   with the tool name, rate limited
    PermissionRequest                    blocked   kind=permission
    Notification permission_prompt       blocked   kind=permission
    Notification elicitation_dialog      blocked   kind=question
    Notification idle_prompt             idle
    Notification agent_needs_input       idle
    Notification agent_completed         done
    Stop                                 idle      finished, waiting for a human
    StopFailure                          error
    SessionEnd                           clear     the record goes away

Anything else is ignored, which is deliberate: an event with no obvious state
is better left alone than mapped to a guess, because a report replaces the
whole record.

Two rules worth knowing, both learned the hard way by prior art rather than
reasoned out here:

  - A subagent never reports. Its events carry `agent_id`, and letting them
    through means a subagent finishing marks the whole pane idle while the
    main turn is still working.
  - `SubagentStop` never reports either, even without `agent_id`, because it
    can arrive after the main turn has already stopped and would revive an
    idle pane.

This exits 0 whatever happens. A hook that fails is a hook that interrupts the
agent, and a status indicator is never worth that.
"""

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, 'tmm-report.sh')

# PreToolUse fires on every tool call, and a batch of parallel reads can be
# dozens in a second. The state does not change between them -- only the tool
# name does -- so they are collapsed to at most one report in this window.
TOOL_REPORT_INTERVAL = 1.0

NOTIFICATION_STATES = {
    'permission_prompt': ('blocked', {'kind': 'permission'}),
    'elicitation_dialog': ('blocked', {'kind': 'question'}),
    'elicitation_url_dialog': ('blocked', {'kind': 'question'}),
    'idle_prompt': ('idle', {}),
    'agent_needs_input': ('idle', {}),
    'agent_completed': ('done', {}),
}


def report(options):
    """Hand one record to the emitter, and never fail because of it."""
    args = ['%s=%s' % (k, v) for k, v in options.items()]
    try:
        subprocess.run(['sh', REPORT] + args, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def rate_limited(session):
    """True if a tool report for this session went out very recently.

    Keyed by session rather than by pane so two agents in one pane cannot
    silence each other, and stored in TMPDIR because it is worth nothing
    across a reboot.
    """
    stamp = os.path.join(
        os.environ.get('TMPDIR', '/tmp'),
        'tmm-agent-status-%s' % (session or 'nosession').replace('/', '_'))
    now = time.time()
    try:
        if now - os.path.getmtime(stamp) < TOOL_REPORT_INTERVAL:
            return True
    except OSError:
        pass
    try:
        with open(stamp, 'w'):
            pass
    except OSError:
        # Cannot keep the timestamp, so do not drop the report either: an
        # unthrottled indicator beats no indicator.
        return False
    return False


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        return
    try:
        hook = json.loads(raw) if raw.strip() else {}
    except ValueError:
        return
    if not isinstance(hook, dict):
        return

    event = str(hook.get('hook_event_name') or '')

    # A subagent's lifecycle is not the pane's. See the module docstring.
    if hook.get('agent_id') or event == 'SubagentStop':
        return

    # `app` is on every report so the sidebar can say which program spoke, and
    # because a report replaces the record: leaving it off one report would
    # erase it.
    base = {'app': 'claude'}

    if event == 'UserPromptSubmit':
        report(dict(base, state='working'))
    elif event == 'PreToolUse':
        if rate_limited(hook.get('session_id')):
            return
        options = dict(base, state='working')
        tool = hook.get('tool_name')
        # The tool name is the honest answer to "what is it doing". A
        # percentage is not available from hooks -- nothing in the event says
        # how many tool calls a turn will take -- so `progress` is left off
        # rather than invented. tmm-report.sh accepts progress= for a program
        # that genuinely knows its own fraction.
        if isinstance(tool, str) and tool:
            options['title'] = tool
        report(options)
    elif event == 'PermissionRequest':
        options = dict(base, state='blocked', kind='permission')
        tool = hook.get('tool_name')
        if isinstance(tool, str) and tool:
            options['title'] = tool
        report(options)
    elif event == 'Notification':
        mapped = NOTIFICATION_STATES.get(str(hook.get('message') or ''))
        if mapped is None:
            return
        state, extra = mapped
        report(dict(base, state=state, **extra))
    elif event == 'Stop':
        report(dict(base, state='idle'))
    elif event == 'StopFailure':
        report(dict(base, state='error'))
    elif event == 'SessionEnd':
        # `clear` removes the record rather than setting a state, so the row
        # stops claiming anything about a session that is gone.
        report({'state': 'clear'})


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never take the agent down over an indicator.
        pass
