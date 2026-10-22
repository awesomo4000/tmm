#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Map a Claude Code hook event onto one OSC 7501 report.

Installed once for every event in settings-snippet.json; the event name
arrives in the JSON on stdin, so one script covers all of them and there is
one place where the mapping lives.

This needs the agent to be in a tmux pane on the server tmm is watching, which
is the ordinary way to run tmm. tmm reads the record from the pane option the
emitter sets; see the README beside this file.

What it never does is replace tmm's screen detector. That works with nothing
installed at all, and still decides every pane that reports nothing.

The transport is tmm-report.sh beside this file. A hook cannot write to the
terminal itself: it runs in its own session with no controlling terminal, and
its stdout goes to the agent rather than the screen. See that script for the
whole story.

The mapping:

    UserPromptSubmit                     working   a turn started
    PreToolUse                           working   with the tool name, rate limited
    PermissionRequest                    blocked   kind=permission, with the tool
    PostToolUse, PostToolUseFailure,
      PermissionDenied, ElicitationResult
                                         working   only from blocked: answered
    Notification permission_prompt       blocked   kind=permission
    Notification elicitation_dialog,
      elicitation_url_dialog,
      agent_needs_input                  blocked   kind=question
    Notification idle_prompt             idle      only from working
    Stop                                 done      finished, not yet looked at
    StopFailure                          error
    SessionEnd                           clear     the record goes away

Anything else is ignored, which is deliberate: an event with no obvious state
is better left alone than mapped to a guess, because a report replaces the
whole record.

Rules worth knowing, each learned the hard way, here or by prior art:

  - A Notification's type is in `notification_type`. `message` is the text a
    person reads ("Claude needs your permission to use Bash"). An earlier
    version keyed on `message` and so never matched a real payload. Only a
    release old enough to send no type is read from its text, and only for
    the two messages it is known to send.
  - Something has to move a pane off blocked once the person answers. Nothing
    did but the next PreToolUse, and the rate limiter could drop that one, so
    approving quickly left `!` showing. The tool events that follow an answer
    now end the block -- but only a block, so a late PostToolUse cannot turn a
    finished turn back to working.
  - Stop is `done`, not `idle`. The protocol's `done` is "finished, with a
    result the person has not seen", which is what the end of a turn is, and
    reporting idle hid the very completion tmm's screen detector would
    otherwise have marked.
  - A subagent never reports. Its events carry `agent_id`, and letting them
    through means a subagent finishing marks the whole pane done while the
    main turn is still working.
  - `SubagentStop` never reports either, even without `agent_id`, because it
    can arrive after the main turn has already stopped and would revive it.

The conditional rules need the state this hook last reported. It keeps that in
a file per session in TMPDIR rather than asking tmux, so the events that fire
on every tool call cost no tmux round trip and usually no report at all.

The mapping follows tuios's Claude Code integration, which cites the Claude
Code hooks documentation for each event; see notes/tuios.md.

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

# By notification_type. A type missing from here is not a state change:
# auth_success, elicitation_complete and elicitation_response say nothing
# about the turn, and agent_completed repeats what Stop already reported.
NOTIFICATION_STATES = {
    'permission_prompt': ('blocked', {'kind': 'permission'}),
    'elicitation_dialog': ('blocked', {'kind': 'question'}),
    'elicitation_url_dialog': ('blocked', {'kind': 'question'}),
    'agent_needs_input': ('blocked', {'kind': 'question'}),
    'idle_prompt': ('idle', {}),
}

# A release too old to send notification_type, read from the two messages it
# is known to send. Anything else from such a release reports nothing, so a
# notification like a successful login never reads as a blocked pane.
LEGACY_MESSAGES = (
    ('needs your permission', 'permission_prompt'),
    ('waiting for your input', 'idle_prompt'),
)

# The events that follow a person answering a prompt.
ANSWERED = ('PostToolUse', 'PostToolUseFailure', 'PermissionDenied',
            'ElicitationResult')


def scratch(session, suffix):
    """A per-session file in TMPDIR, worth nothing across a reboot.

    Keyed by session rather than by pane so two agents in one pane cannot
    disturb each other.
    """
    name = 'tmm-agent-status-%s%s' % (
        (session or 'nosession').replace('/', '_'), suffix)
    return os.path.join(os.environ.get('TMPDIR', '/tmp'), name)


def last_state(session):
    """The state this hook last reported for the session, or '' if unknown."""
    try:
        with open(scratch(session, '.state')) as f:
            return f.read().strip()
    except OSError:
        return ''


def report(session, options):
    """Hand one record to the emitter, and never fail because of it."""
    args = ['%s=%s' % (k, v) for k, v in options.items()]
    try:
        subprocess.run(['sh', REPORT] + args, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return
    try:
        with open(scratch(session, '.state'), 'w') as f:
            f.write(options.get('state', ''))
    except OSError:
        pass


def rate_limited(session):
    """True if a tool report for this session went out very recently."""
    stamp = scratch(session, '')
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


def notification_type(hook):
    kind = str(hook.get('notification_type') or '')
    if kind:
        return kind
    message = str(hook.get('message') or '').lower()
    for phrase, legacy in LEGACY_MESSAGES:
        if phrase in message:
            return legacy
    return ''


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
    session = hook.get('session_id')

    # A subagent's lifecycle is not the pane's. See the module docstring.
    if hook.get('agent_id') or event == 'SubagentStop':
        return

    # `app` is on every report so the sidebar can say which program spoke, and
    # because a report replaces the record: leaving it off one report would
    # erase it.
    base = {'app': 'claude'}

    def tool_title(options):
        tool = hook.get('tool_name')
        if isinstance(tool, str) and tool:
            options['title'] = tool
        return options

    if event == 'UserPromptSubmit':
        report(session, dict(base, state='working'))
    elif event == 'PreToolUse':
        # Collapsed only while the pane is already working: then it changes
        # nothing but the tool name. Out of any other state it is a change
        # that has to get through.
        if last_state(session) == 'working' and rate_limited(session):
            return
        # The tool name is the honest answer to "what is it doing". A
        # percentage is not available from hooks -- nothing in the event says
        # how many tool calls a turn will take -- so `progress` is left off
        # rather than invented.
        report(session, tool_title(dict(base, state='working')))
    elif event == 'PermissionRequest':
        report(session, tool_title(dict(base, state='blocked', kind='permission')))
    elif event in ANSWERED:
        # These fire on every tool call, so in the ordinary case this reads
        # one small file and stops.
        if last_state(session) == 'blocked':
            report(session, dict(base, state='working'))
    elif event == 'Notification':
        mapped = NOTIFICATION_STATES.get(notification_type(hook))
        if mapped is None:
            return
        state, extra = mapped
        # idle_prompt fires after the prompt has sat unanswered for a while.
        # It only corrects a pane still showing working after a Stop that
        # never arrived; a finished turn has to stay done.
        if state == 'idle' and last_state(session) not in ('working', ''):
            return
        report(session, dict(base, state=state, **extra))
    elif event == 'Stop':
        report(session, dict(base, state='done'))
    elif event == 'StopFailure':
        report(session, dict(base, state='error'))
    elif event == 'SessionEnd':
        # `clear` removes the record rather than setting a state, so the row
        # stops claiming anything about a session that is gone.
        report(session, {'state': 'clear'})


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never take the agent down over an indicator.
        pass
