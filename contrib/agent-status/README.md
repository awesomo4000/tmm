# agent-status/

Make an agent report what it is doing, so the tmm sidebar can show a state the
agent knows rather than one worked out from its screen.

This does not replace the screen detector, and is not meant to. That detector
works with no cooperation from anything -- no hooks, no config, no agent
support, nothing installed -- which is why it stays the default and keeps
running for every pane. What it cannot do is be certain: quiet output is never
a completion, a transition between two polls is missed, an unrecognised screen
stays unknown, and `error` has no screen it can be recognised from at all. A
report has none of those failure modes, so where one exists it is believed
first. Where none exists, nothing changes.

tmm already reads OSC 7501 out of a pane and draws it (`src/surface.zig`,
`src/sidebar.zig`). What was missing was anything that emits it. These are the
two pieces: a transport, and one mapping from Claude Code hook events onto it.

Nothing here is installed by default, and nothing touches your agent config
unless you run the installer or edit the file yourself.

## The files

- **`tmm-report.sh`** — the emitter. Takes `key=value` options and writes one
  OSC 7501 record to the tty of the tmux pane it is running in. Useful on its
  own, from anything that knows what it is doing: a build script, a deploy, a
  long migration.

      tmm-report.sh state=working app=terraform progress=40
      tmm-report.sh state=blocked kind=permission
      tmm-report.sh state=done app=terraform
      tmm-report.sh state=clear

  It does nothing at all outside tmux, so it is safe in a script that runs in
  both places.

- **`claude-status-hook.py`** — the mapping. Reads a Claude Code hook event
  from stdin and calls the emitter. One script for every event; the event name
  is in the JSON.

- **`settings-snippet.json`** — the `hooks` block to merge into your Claude
  Code settings.

- **`install.sh`** — copies both scripts to `~/.claude/hooks/tmm/` and prints
  the snippet. It does not edit your settings; merging is left to you, because
  settings files have other hooks in them and clobbering those would be worse
  than a manual step.

## What this needs to be running

The agent has to be in a tmux pane on the server tmm is watching. That is the
only requirement, and it is the normal way to use tmm, which is a view over
tmux rather than over one shell.

tmm reads the record from the `@tmm_status` pane option, which it reads for
every pane on the server in the `list-panes -a` query it already makes, so a
report from any session reaches it. That route is necessary rather than
belt and braces: tmm talks to tmux over control mode and never sees a pane's
own output, and even a client that decoded the control stream would be told
about output in the one session it is attached to and no other -- measured,
not assumed: a control client attached to session A hears nothing about
output in session B.

The emitter also writes the OSC 7501 itself to the pane tty. That is the
protocol, it costs one write, and a terminal that reads OSC 7501 picks it up
when the agent runs outside tmux. Inside tmux it goes nowhere, because tmux
consumes an OSC it does not implement.

Nothing here is a failure mode when tmm is not up. The emitter exits 0 and
silently with no tmux, with a stale pane id, and with nothing reading the pane.
Forty reports into a pane running a full-screen TUI leave its display byte for
byte unchanged, so leaving the hooks installed costs nothing.

### Why the record is not scraped instead

A reasonable idea, since tmm already captures pane text for the detector: have
the capture look for OSC 7501 too. It cannot work. tmux parses the pane's
output into a grid and an OSC it does not implement is consumed there, so the
sequence never reaches the screen `capture-pane` renders -- with `-e` or
without it, measured both ways. The pane option is what gives the capture path
a reliable signal instead, and it rides the same query.

## Install

    contrib/agent-status/install.sh

Then merge `settings-snippet.json` into `~/.claude/settings.json` under
`hooks`. If you already have hooks on those events, add this one to the
existing `hooks` array rather than replacing it.

## What maps to what

| Event | Reported |
| --- | --- |
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `working`, with the tool name, at most once a second |
| `PermissionRequest` | `blocked`, `kind=permission` |
| `Notification` `permission_prompt` | `blocked`, `kind=permission` |
| `Notification` `elicitation_dialog` | `blocked`, `kind=question` |
| `Notification` `idle_prompt`, `agent_needs_input` | `idle` |
| `Notification` `agent_completed` | `done` |
| `Stop` | `idle` |
| `StopFailure` | `error` |
| `SessionEnd` | `clear` |

Anything else is ignored on purpose. A report replaces a record completely, so
mapping an event whose meaning is unclear would overwrite a known state with a
guess.

Subagent events never report. They carry `agent_id`, and `SubagentStop` is
skipped even without one, because it can arrive after the main turn has
already stopped and would otherwise mark an idle pane as working. That rule is
taken from the Herdr integration rather than reasoned out here.

## Why it writes to the pane tty

This is the part worth reading before changing any of it, because the two
obvious routes are both closed and were measured closed, not assumed:

1. **The hook cannot write to the terminal.** Claude Code command hooks run in
   their own session with no controlling terminal: opening `/dev/tty` fails,
   inside tmux and out. Their stdout goes to the agent — recorded in the debug
   log, or fed back as context on a few events — and never to the screen.
2. **`terminalSequence` does not carry it.** The documented way for a hook to
   emit an escape sequence is a `terminalSequence` field in its JSON reply,
   but it passes a short allowlist: window and icon titles, desktop
   notifications, a bell. An OSC 7501 put through it does not arrive.

What a hook *does* inherit is the environment of the pane it ran in, including
`$TMUX` and `$TMUX_PANE`. So the emitter asks tmux for `#{pane_tty}` and
writes there. A write to a pane's tty from a process with no controlling
terminal arrives as that pane's output, which is the same path a `printf` from
a shell in the pane takes: tmux turns it into `%output`, and tmm parses the
sequence out of it.

`$TMUX` also carries the socket, which matters — tmm is often watching a
server that is not the default one, and a bare `tmux` would address the wrong
one.

`tests/agent_hooks.py` runs these scripts with the hooks detached into their
own session, so a change that reintroduces a dependency on `/dev/tty` fails
the suite rather than passing it.

## Why there is no percentage

`progress=N` is in the protocol and the sidebar draws it, but the Claude Code
hook never sends one: nothing in a hook event says how many tool calls a turn
will take, so any percentage would be invented. What the hook does know is
which tool is running, which it sends as the title, and the sidebar shows that
during long work instead. A program that genuinely knows its own fraction —
a build, a deploy, a migration — should pass `progress=` to `tmm-report.sh`
directly.

## The other agents

Only Claude Code is wired up, because it is the only one that could be tested
end to end here. The shape transfers: `tmm-report.sh` has nothing agent
specific in it, so another agent needs only its own mapping from its own
lifecycle events, and whatever it offers in place of hooks. The two things to
check first for any of them are the two above — whether its hook has a
terminal, and whether it passes the pane environment through.
