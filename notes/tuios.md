# Notes: how tuios integrates agent harnesses, and its OSC 7501

Read from a depth-1 checkout of [tuios](https://github.com/Gaurav-Gosain/tuios)
at commit `9c8f0df`, 10/22/2026, against the Program Status Protocol
specification at revision 0.4. tuios is MIT. Twenty of its 24 detection
manifests adapt rules from [herdr](https://github.com/herdrdev/herdr), Apache-2.0,
the same project tmm's `src/status.zig` adapts.

Nothing here was run. The tuios claims are from its code where the code was
read, and from its docs where that is said.

## What tuios is, relative to tmm

A tmux replacement, not a tmux client. Its daemon owns every pseudoterminal, so
it has each pane's bytes natively, and kitty graphics pass through without
anything to tap around. It never watches a real tmux. Its tmux control-mode
code (`internal/tmuxcompat/control.go`) runs the other way: `tuios tmux-shim`
puts a fake `tmux` first on PATH and *serves* `-C`/`-CC`, so tools that drive
tmux (Claude Code agent teams) get tuios panes. Reading a real tmux over control
mode, which is what tmm does, has no counterpart there.

## OSC 7501: correct, against revision 0.4

Its parser is `progstatus/progstatus.go`, a standalone module
(`tuios.dev/progstatus`). The code and the docs both say revision 0.2. That is
a stale label rather than a gap: what 0.3 and 0.4 changed needs no parser
change. 0.3 said absent `progress` means indeterminate and that programs may
report without detecting support first; 0.4 let the support reply list
`states` and `kinds` (optional), explained why control characters are refused
and what `app` is for, and removed terminfo.

| Rule (rev 0.4) | tuios |
|---|---|
| Key is `[a-z]+`, at most 16 bytes; over the limit discards the report | Yes, both |
| Value set `[A-Za-z0-9_.,+/=-]`; malformed pair skipped, rest applied | Yes |
| Whitespace around keys and values removed | ASCII space and tab only, deliberately: NBSP is outside the value set, so it makes the pair malformed rather than trimmable |
| Repeated key, last value wins | Yes, values gathered then checked once |
| Unknown key ignored | Yes |
| No `state`, or an unknown one, ignores the report | Yes |
| Bad `id` ignores the report and MUST NOT fall back to root | Yes, and it resolves an ambiguity in the spec: a pair with a byte outside the value set is "malformed, skipped", which for `id=a b` would land on root, so `id` alone discards instead of skipping |
| `app` over 32 bytes discards; outside its set treated as absent | Yes, both |
| `title`/`msg` encoded size checked before decoding | Yes |
| Bad base64, invalid UTF-8, or a control character (C0, DEL, C1) discards the whole report | Yes. Stricter than required: padding optional, but padding present must be right and the unused tail bits zero, so each text has one encoding |
| `kind` only with `blocked`, unknown kind absent | Yes |
| `progress` 0-100 only with `working`/`blocked`, else indeterminate | Yes |
| `clear` removes the record and everything under it; no `id` clears all | Yes; a clear report carries only its id |
| Support reply is `?` | Bare `OSC 7501 ; ?`, with the query's own terminator. Allowed: listing `states`/`kinds` is optional |
| Records per terminal 256, at least 64, LRU eviction | 256, least recently changed evicted |
| Drop `working`/`blocked` at process exit and at a new prompt (OSC 133 A); MAY drop `idle`; keep `done`/`error` | Yes. Exit is detected by the foreground process group, polled every 2 s; `idle` is dropped too |
| `done`/`error` lifetime is the terminal's call | Cleared when the person types in the pane (not keys sent by scripts) |
| RIS clears all; DECSTR and alt-screen switches do not | Yes |
| OSC 9;4: MAY map to root, SHOULD stop after any OSC 7501 | Reads 9;4 as agent state, not as the root record, and stops for that pane after an OSC 7501 until RIS |
| Security: no markup, disarm bidi, nothing echoed back, name the source, rate-limit side effects | Yes; side effects at most once per 30 s per pane |

Two caveats, both documented by tuios rather than found:

- A program that reports and exits in the same instant can be gone before the
  2 s detector reads the foreground group, so its `working` record survives
  until the next prompt. A shell that emits OSC 133 has no such gap.
- Its lifetime table keeps records when "the pane's own process" exits. That
  reads as a MUST violation, but in tuios a pane whose own process exits
  usually closes, taking its records with it. Worth checking before calling it
  one.

Beyond the spec, tuios also *sends* OSC 7501 to the terminal it runs in, one
record per pane with id `<session>/<pane>`, after asking that terminal `?`,
changed records only, at most every 250 ms, cleared on detach.

## Harness integrations: not OSC 7501

The hooks do not write OSC 7501. Every harness reports through
`tuios agent-hook <harness>`, which reads the hook payload on stdin, translates
it (`internal/integration`, one `hook_*.go` per family) and sends a
`set-agent-state` verb to the daemon over its socket. OSC 7501 is the separate
route for arbitrary programs. A hook finds its pane from `--window`, then
`TUIOS_PANE_ID`, then the daemon resolving the process's terminal, then the
parent processes; tmm's equivalent is `$TMUX_PANE` alone.

`tuios integration install <harness>` writes the harness's own config, removes
only what it wrote on uninstall, versions each integration so `status` can say
an install is stale, and refuses when the harness's config directory does not
exist. Each target cites the format documentation it was written from.

### State versus session

Each target reports one of two things, and the split is the most useful idea
here:

- **state**: the hooks cover the whole turn, so the pane's state comes from
  them.
- **session**: the hooks only name the conversation (`set-agent-session`), and
  the state keeps coming from the screen rules. Used where the hook surface
  misses transitions -- an interrupt, a cancelled approval, a turn ending --
  because a hook report outranks every screen rule, so one missed event would
  pin a pane on `working` until the harness exits. herdr reached the same split.

| Harness | Reports | Mechanism | Where |
|---|---|---|---|
| Claude Code | state | settings.json hooks, 14 events | `$CLAUDE_CONFIG_DIR` or `~/.claude` |
| Codex | state | hooks.json, Claude's shape; Interrupt and SessionEnd capped at 3 s | `$CODEX_HOME` or `~/.codex` |
| Gemini CLI | state | settings.json hooks, timeouts in ms (SessionStart, BeforeAgent, BeforeTool, AfterTool, Notification, AfterAgent, SessionEnd) | `~/.gemini` |
| opencode | state | JS plugin; V2 adds a client plugin so the environment names the pane | `~/.config/opencode/plugins` |
| Kilo | state | the opencode plugin (Kilo is a fork) | `~/.config/kilo/plugin` |
| Amp | state | TS plugin run by Bun (session.start, agent.start/end, tool.call/result) | `~/.config/amp/plugins` |
| Copilot CLI | state | `hooks/tuios.json`, bash and powershell commands | `$COPILOT_HOME` or `~/.copilot` |
| Cursor Agent | state | hooks.json v1; no permission hooks, since they block on an empty answer | `~/.cursor` |
| Kimi Code | state | `[[hooks]]` tables in config.toml | `~/.kimi-code` |
| Qwen Code | state | settings.json, Claude's shape; timeouts written as >= 1000 so old and new releases agree | `~/.qwen` |
| **Pi** | state | TS extension | `$PI_CODING_AGENT_DIR` or `~/.pi/agent/extensions` |
| **oh-my-pi** | state | TS extension, Pi's shape but its own events; must not overwrite a Pi install | `~/.omp/agent/extensions` |
| Antigravity | session | hooks.json, PreInvocation | `~/.gemini/config` |
| Crush | session | crush.json PreToolUse, the only event it has | `~/.config/crush` |
| Devin | session | config.json hooks | `~/.config/devin` |
| Droid | session | settings.json SessionStart | `~/.factory` |
| Grok | session | `hooks/*.json`, SessionStart spelled three ways | `~/.grok` |
| Hermes | session | Python plugin plus `plugins.enabled` in config.yaml | `~/.hermes/plugins` |
| Qoder | session | settings.json SessionStart | `~/.qoder` |

### Pi and oh-my-pi, tmm's open TODO

The two agents tmm has no mapping for. tuios's extensions
(`internal/integration/assets/{pi,omp}/`) shell out to `tuios agent-hook` with
these events:

- **Pi**: `session_start` (with `busy` from `ctx.isIdle()`), `agent_start`,
  `agent_settled` (only when `ctx.isIdle()`), `ui_prompt_start` (a blocking
  prompt, so needs input) and `ui_prompt_end`.
- **oh-my-pi**: `session_start`, `agent_start`, `agent_end` (skipped when
  `event.willContinue`), `tool_approval_requested`, `tool_approval_resolved`.
  Only from the main TUI (`mainTUI(ctx)`), not from a nested context.

Both are code extensions, not config hooks, so tmm's equivalent would be an
extension that runs `contrib/agent-status/tmm-report.sh`.

## Claude Code: tuios's mapping against tmm's hook

| Event | tuios | tmm (`claude-status-hook.py`) |
|---|---|---|
| SessionStart | idle, with session id; skipped when it is a compaction restarting mid-turn | not mapped |
| UserPromptSubmit | working | working |
| PreToolUse | working | working with the tool as title, rate-limited to 1 per second |
| PermissionRequest | needs input, kind approval, holds for the Inbox | blocked, kind permission |
| PostToolUse, PostToolUseFailure, PermissionDenied, ElicitationResult | working, **only if the pane is in needs input** | not mapped |
| Notification | by `notification_type`; falls back to the message text only for old releases that send no type | by `message`, which is human text |
| Stop | **done** | idle |
| StopFailure | error, with `error_type` | error |
| SessionEnd | none (cleared) | clear |
| SubagentStart/Stop | tracked as activity, without touching the pane's state | ignored |

## What this found wrong in tmm

These carry into the cleanup:

1. **`Notification` never fires on a real payload.** The hook reads `message`
   and compares it with `permission_prompt`, `idle_prompt` and the rest, but
   Claude Code puts those in `notification_type`; `message` is text such as
   "Claude needs your permission to use Bash". The removed `agent_hooks.py`
   passed because it sent the code in `message`, the same wrong assumption.
2. **Approving a permission quickly leaves `!` up.** Nothing but the next
   `PreToolUse` moves a pane off blocked, and the rate limiter, stamped only by
   `PreToolUse`, drops one that comes within a second of the last. tuios moves
   off needs input on `PostToolUse` and its siblings, and only from needs input,
   so the condition cannot turn a finished pane back to working.
3. **`Stop` reports idle.** The spec's `done` is "finished, with a result the
   user has not seen", which is a turn ending; tmm's own unread mark exists to
   say exactly that for inferred states.
4. **A stale record never expires.** `@tmm_status` stays until a hook clears
   it, so an agent killed with `kill -9` reads as working forever. The spec's
   MUST is to drop `working`/`blocked` when the process exits. tmm has no pane
   bytes, so no OSC 133, but its process tree already knows when a pane's agent
   is gone.
5. **A long title is dropped, not truncated.** `decodeTitle` decodes into a
   24-byte buffer and returns null above it, so a 29-byte title, legal at up to
   192, shows nothing. Measured. The test meant to prove truncation passes
   vacuously: its input decodes to 27 bytes and is dropped too, and "length at
   most 24 and valid UTF-8" holds for an empty string.
6. **Lenient where the spec discards.** A title that is valid base64 of a
   control character, or not base64 at all within the value set, drops only the
   title; the spec discards the whole report. `kind` and `progress` are
   accepted with any state, where the spec ignores them outside
   `blocked`/`working`. The key and value grammars are not checked.

Not wrong, but different: tmm keeps one record per pane, since the pane option
is a single string, where the spec has an id hierarchy. The emitter only ever
writes the root record, so nothing is lost today.

## Worth taking later

- The **detection manifests** (`internal/harness/manifests/*.toml`, 24 agents):
  process match (`comm`, `argv0`, `argv_path`, `exe_glob`), screen rules over
  the last N lines scoped by region (`prompt_box`,
  `after_last_horizontal_rule`), title rules, OSC 9 notification rules, and a
  transcript reader. Each rule names the tool version it was measured on. Same
  herdr lineage as `src/status.zig`, which knows 5 agents to their 24.
- The **state/session split** above, before tmm adds hooks for agents whose
  hook surface has holes.
- **`tuios status`** as a model for `tmm-report.sh`: it refuses a report a
  terminal would have to discard, and says why, rather than sending it.
