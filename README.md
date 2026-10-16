# tmm : tmux micro manager

<p align="center">
  <img src="img/tmm-micromanager.webp" width="800" alt="A cel-shaded pointy-haired boss micromanaging tmux windows beside a tmm sidebar for goose-protocol and haunted-toaster." />
</p>

A skinny libvaxis sidebar for ordinary tmux sessions. Run it beside your workspace terminal. One scrolling list contains servers, displays, and sessions with every pane and its current directory.

## Build and run

Requires Zig 0.16.0 and tmux. Zig fetches [libtmux](https://github.com/awesomo4000/libtmux) and libvaxis from public repositories, with revisions and content hashes pinned in `build.zig.zon`. Tested with tmux 3.7c and libtmux revision `c63d5aa24d95c8bf757f8ad0b79f81da98275dbf`. No sibling checkout or JavaScript runtime is needed.

The integration suite also passes on Ubuntu 24.04 under WSL with tmux 3.4. Linux x86-64 and ARM64 builds do not require libc. On older tmux versions without centered messages, display identification appears in the status line for five seconds. See [portability-report.md](portability-report.md) for build results and the remaining native Windows blockers.

```sh
zig build
./zig-out/bin/tmm
```

The default launch lists the default server and discovers other running sockets in `$TMUX_TMPDIR/tmux-UID`, or `/tmp/tmux-UID`. Discovery happens at startup. Custom socket paths can be added explicitly:

```sh
./zig-out/bin/tmm -L work --server experiments
./zig-out/bin/tmm -S /tmp/work.sock --server-path /tmp/other.sock
```

`-L` or `-S` selects the initial server and disables automatic discovery, useful for isolated setups. Repeat `--server` or `--server-path` to add entries. Clicking a server clears the previous display target before loading its displays and sessions.

## Split mode

By default tmm is the whole window, meant to sit beside a tmux client in another window. `--shell` instead splits its own window: the sidebar on the left, a one-column divider, and a shell on the right.

```sh
./zig-out/bin/tmm --shell
./zig-out/bin/tmm --shell --split 36
```

The right side is an ordinary shell on an ordinary pty, with job control and live resizing, so `tmux attach` works in it exactly as in any terminal. tmm is not a multiplexer here; it draws both sides into one window so the sidebar costs no second window and no second click to focus.

`--split` sets the starting sidebar width in columns and implies `--shell`; without it the sidebar starts at its content width. Drag the divider to resize, which resizes the shell with it. F12 moves keyboard focus between the sidebar and the shell, and clicking either side focuses it. The cursor shows which side has the keyboard. With focus on the shell, every key goes to it, so `q` quits tmm only from the sidebar.

Once the shell has focus the mouse goes to it too, in whatever reporting mode and format the program inside selected, so a `tmux` in the region takes clicks on its panes and the wheel scrolls it rather than the sidebar. A program that never asked for mouse reporting sees nothing, and a click still only focuses. Forwarding is gated on focus so a stray hover does not reach a program the user is not working in.

Images are parsed but not drawn. Without `--shell` nothing changes: no pty is opened and no terminal is created.

The region owns the backing bytes for the characters it draws, because libvaxis keeps a cell's grapheme slice rather than copying it and re-renders unchanged cells from the screen it retains. Anything shorter-lived decays as soon as a frame repaints only the sidebar.

A modifier key pressed on its own is not forwarded unless the program inside asked for every key as an escape code. Terminals that speak the kitty keyboard protocol report modifier keys, and a program that turned on only disambiguation decodes such a report as text, which used to insert U+E061 -- a blank-looking character -- when you pressed shift.

Every key already queued for the region goes to it at once. A key bound for the region changes nothing the sidebar draws, so there is no reason to draw between two of them, and taking one per frame capped typing at the frame rate: ten keys pressed together used to arrive 24ms apart, the last of them past 250ms. The render then waits out a frame budget, 16ms by default and `TMM_FRAME_BUDGET_MS` to change or disable it, and hands over the moment input arrives. Only the render waits: everything before it is the frame's layout, which is also where the clamped split, the scroll offset, the hit-test extents and the resize the region is owed are computed, and skipping that is not a deferred redraw but a dropped update.

The draw still waits around 20ms for the surface lock under continuous output, and that is now the whole cost of a frame. Taking the lock less often is what would help: slicing the parse so it is released every 1KB was measured and reverted, because a parser that re-acquires in a tight loop barges past a waiter that has to be woken, and the wait grew to 23ms.

Setting `TMM_FRAME_LOG` to a path appends where frame time goes, as a mean and a peak over sixty frames rather than a line each, because a line per frame costs an open and a write inside the thing being measured. The phases are the sidebar, the region or panes, and the render to the real terminal. The region phase begins by taking the surface lock, so it includes waiting for it: against a program writing continuously that wait is the whole cost, around 11ms, while the blit it is waiting for takes 0.25ms and the render 0.6ms. The parser holds that lock for a whole 16KB chunk, and `sendKey` needs the same lock, so a keypress waits behind the parse.

A `.pty` wakeup carries nothing: the worker has already fed the output and a draw reads the newest state, so a backlog of them collapses into the single draw they all ask for, and a real event found behind the backlog is handled before that draw. One 512-slot queue carries both output wakeups and input, so without this a keypress waited behind every queued redraw: a program writing continuously took a second to see a key, measured at a median of 1003ms, against 0.1ms when it was quiet.

Setting `TMM_INPUT_LOG` to a path appends one line per key and mouse event in the region: what the outer terminal reported, which keyboard mode the program inside had selected, and the exact bytes it was sent. That is the whole boundary an input bug lives on, and reading it beats inferring any of the three from how a program misbehaves.

## Compositor mode

`--panes` composites a tmux session's panes on the right instead of a shell, with `--session` to pick one. tmm is the terminal for every pane: it attaches a control client, sizes it with `refresh-client -C` so tmux re-tiles to the space available, builds one terminal per pane from the layout, and feeds each one the raw `%output` for its pane. Keys go back the other way as `send-keys -H`.

Neither direction passes through tmux's own terminal emulation. That is what makes it possible to give a pane capabilities tmux does not have: `%output` is tapped before tmux's parser runs, so a pane's bytes arrive verbatim, and `send-keys -H` carries any byte back. Clicking a pane moves the keyboard to it.

tmux still owns the session, the windows, the processes, the scrollback and the persistence, and still delivers SIGWINCH itself. tmm never resizes a pane.

Kitty graphics are parsed and stored per pane but not yet drawn, scrollback is not reachable, and only the session's current window is composited.

## Navigation

Hover highlights an item; click selects it. Wheel scrolling moves the list without activating anything. `j`/`k` or arrows move among actionable rows; Enter activates. `q` or Ctrl-C exits.

1. Pick a server.
2. Pick the display you want to control. Each display row shows `terminal app : session name`, for example `Ghostty : tmm coding`. Parent-process tracing finds the terminal app; matching names get a tty suffix for disambiguation, and unknown owners fall back to the tty. SSH connections are labeled SSH because the remote terminal app is not visible.
3. Click a pane to show its exact session, window, and pane. To switch a session without choosing a pane, highlight its name and press Enter.

Click a session name to rename it inline. The first text you type replaces the existing name. Enter saves, Escape cancels, and arrows, Backspace, and Ctrl-U edit the field. Renaming uses the stable session ID and does not switch displays. A duplicate or invalid name leaves the editor open for correction.

`--client` can preselect an attached tty at startup. `--label main-workspace` gives the selected display an invocation-local friendly label. Internal IDs and PIDs are not shown in the sidebar.

Click `blink` below the displays, or press `b`, to identify the selected display. Hovering a display and pressing `b` identifies that row instead. The chosen terminal shows a text marker steadily for five seconds; other terminals are unaffected. Terminal output continues updating and key presses do not dismiss the label early.

The current pane is read from `list-clients`, which expands its formats per client. `display-message -c <client>` looks like the way to ask where one client is, but `-c` only selects the client for client-specific formats: the target the formats expand against is the server's current pane, so it answers the same for every client and does not move when a client navigates.

The active server, selected display, active session, and current pane use brighter text without inverse backgrounds. Entries use a subtle background for selection and hover, spanning the widest content in the column, clipped to the terminal width. Pane backgrounds cover both the name and directory. A `▸` at the left edge marks the selected display’s current pane; hover does not move that marker. Click `[new]` beside the sessions heading to enter a name, then Enter to create or Escape to cancel. Creation uses the selected display’s current pane directory, names the session and first window, and switches that display into the new session. Other displays stay where they are. Select a display before creating a session. Click either the pane name or its directory to focus that pane on the selected display. The current pane marker follows native tmux navigation too. Each pane's current directory is indented beneath its row, with the home directory abbreviated to `~`. It follows changes to that pane's working directory. Session paths are not displayed.

## Agents

Every pane appears under its session. Ordinary panes show their current command; agent panes show their agent name and status indicator. Codex and Claude status is inferred from known controls near the live bottom of the pane screen and from recognized terminal-title signals. Claude activity lines are recognized even when they omit the interrupt hint. The detector adapts selected rules from [Herdr](https://github.com/herdrdev/herdr/tree/b9ce96869e89937278d673d70ae4c135dd318469/src/detect/manifests); provenance and its Apache license are recorded in `THIRD_PARTY_NOTICES.md`.

| Symbol | Meaning |
| --- | --- |
| `●` | Working |
| `!` | Waiting for approval/input |
| `✓` | Completion awaiting acknowledgement |
| `○` | Idle, no outstanding completion |
| `?` | Present, status unknown |

Known working-to-idle transitions require two consecutive idle samples before producing a completion. A first observation of an already-idle process does not prove a completed turn. Explicit `@agent_state=done:<receipt>` can establish a completion immediately. A checkmark remains until clicking that agent successfully navigates to its pane. Acknowledgement applies to the exact receipt and process identity shown when clicked, so an older click cannot clear a newer completion. Outstanding completions remain visible when the pane starts another turn.

The controller also reads explicit `@agent_hint`, `@agent_state`, `@agent_session_id`, and `@agent_status_text`. Nonempty explicit state overrides screen classification. Without a hint it recognizes executable names for Codex, Claude, Aider, OpenCode, and Gemini through pane process ancestry. Automatic screen classification currently supports Codex and Claude only; other agents can report explicit states.

Agent screens are re-captured when the pane produces output. `%output` on the control stream is exact and per pane, but tmux only sends it for the session that stream is attached to, so `window_activity` covers every other session. It is reported for every window whatever any client is looking at, and rides along with the pane listing at no extra query.

Screen detection is heuristic, not an agent protocol. Quiet output alone is never a completion. Unsupported, changed, or unreadable screens remain unknown. Transitions entirely between polls can be missed. Explicit metadata can outlive its writer. Receipt tracking is local to the current controller worker and resets on restart or server switch; it is not yet durable. Automatic acknowledgement from GUI focus is not implemented. `--dump` includes `status_source` and `status_rule` for inspection, but its one-shot collection does not include the running controller's unread history.

Pane navigation validates the pane's membership in the requested session and window before switching. tmux active windows and panes have ordinary shared semantics: other clients viewing the same session/window can observe those selections. Only the chosen client's attached session is switched.

## Inspection and tests

```sh
./zig-out/bin/tmm --help
./zig-out/bin/tmm -L work --dump
zig build test
python3 tests/integration.py
```

`--dump` emits a read-only JSON snapshot without opening the UI. Build before running integration tests. Tests use unique sockets and disposable files under `/tmp`, never the default server. They cover shell and agent pane navigation, client isolation, sidebar mouse input, blink, unusual names and paths, resizing, disconnection, switching servers, failures, and exit. tmm runs inside its own region, which is the shortest statement of how complete the region is: `tests/split_shell.py` nests it three deep and checks that a keystroke typed at the bottom reaches the tmux server. Focus descends by clicking, which rebases the column at each level; F12 does not descend, because every level matches it before forwarding.

A keystroke takes no lock. The parser publishes the encoder's view of the terminal's modes as one atomic word, and `sendKey` reads that snapshot, encodes, and writes to the child. Reading a snapshot one parse behind is not a loss of accuracy: the child has not seen the bytes the parser is working through either, so a key arriving mid-parse genuinely precedes them, and the lock gave the same answer only slower. Compositor keys are formatted into a stack buffer too, because the command used to be built with the allocator once per keystroke.

The draw does not take that lock either. The render state has its own, and the parser publishes into it: the parse lock covers a whole 16KB of output, while the render lock covers one update, about 0.01ms. A draw waiting on it therefore waits for an update rather than for a parse, which is what removes output volume from the latency of a keystroke. The draw's own phase went from 22ms to 0.36ms, and a key under continuous output now costs what it costs on a quiet terminal: 0.1ms median and 0.3ms at worst in `--shell`, 0.2ms and 0.8ms through a tmux pane.

`std.Io.Mutex` is a plain futex with no fairness, so a woken waiter re-races for it and can lose repeatedly, and what a waiter pays follows how much of the time the holder holds it rather than how long any single hold lasts. That is why three lock-side remedies all failed and are recorded in `src/surface.zig`: slicing the parse took the draw's wait from 11ms to 23ms, a parser yield changed nothing, and halving the acquisitions left the frame unchanged because the remaining one grew to fill it. Splitting the state in two is what worked, not tuning the lock.

One semantic change came with it. `RenderState.dirty` means changed since the last update, which was the same as changed since the last draw only while the draw was the one calling update. With the parser calling it, two updates between two draws would report the second as clean and lose the frame, so a `needs_draw` flag is set by the publisher and consumed by the draw.

`tests/tmux_floor.py` measures what tmux alone costs on that path, with tmm not involved: a control client writes `send-keys -H` down the pipe of a long-lived `tmux -C attach` and the process in the pane records when its own read returns the byte. It is 0.09ms median and 0.20ms at worst while 199MB of output is drained, and faster under load than idle, because tmux is already awake and pays no wakeup. Keys are never a process spawn. Whatever compositor-mode latency remains is tmm's.

`tests/keyscope.py` is a key scope to run by hand: it blasts the screen and lists every key that arrives through it, with the raw bytes in hex, a description in words, the codepoint, the modifiers held, which encoding it came in (a raw byte, a legacy CSI, SS3, or the kitty CSI u form), the associated text, and the gap since the previous key. Run it bare in a terminal first to see what that terminal does on its own, then run it inside the region and compare, because most of what it measures belongs to the terminal and the keyboard rather than to whatever sits between them. F1 toggles the blast, F2 cycles the kitty flags, F3 resets the statistics, F10 quits; ctrl-c quits only when pressed twice, so that a single one stays inspectable. `--self-test` checks the decoder against known sequences with no terminal at all, and is what the test task runs.

Three numbers, measuring three different things. The gap between arrivals is delivery jitter when a key is held, because the terminal repeats at a fixed cadence: it is what exposes a loop dispatching one key per redraw, which quantises the gaps to a frame. A hold is press to release for one key, which needs the kitty event-types flag. The echo is a DSR cursor query timed until the reply, and the reply is written by whatever is emulating the terminal, so inside tmm it measures tmm's own parse path and the lock a keypress contends for. What no program in that position can measure is the time from the key going down, because nothing in the bytes says when it was pressed; that needs a sender with a clock, which is `tests/keylag.py`.

Key release events do not reach a program inside the region yet. libvaxis asks the outer terminal for kitty flags 29, which omits the event-types bit, so releases are never reported to tmm and tmm cannot forward what it never receives. The scope shows them when run bare in a terminal that speaks the protocol.

`tests/keylag.py` measures what the program inside actually waits: the harness reads the monotonic clock immediately before writing a key byte into tmm's pty, and the child reads it again the instant its own `read` returns, which makes the difference pure delivery latency with none of the harness in it. It is measured quiet and against a child writing continuously, because only the loaded case ever regressed. The child's stdout is nonblocking and drops EAGAIN, so a latency it reports is time tmm took and not time the child spent stuck in `write`. The loaded figure includes however fast the harness itself drains tmm's output, so treat it as an upper bound.

`tests/split_shell.py` covers `--shell`: the divider geometry, focus, keys reaching the child, the child's output reaching the display, a real `tmux attach` inside the region at the region's exact size, a click and a wheel event inside it moving that client's pane and entering copy mode, box drawing surviving a redraw it took no part in, three levels of nested tmm, and divider drags resizing both sides. Display assertions go through `tests/screen.py`, which replays the cursor, because libvaxis emits only the cells that changed and a rendered line does not appear contiguously in the output bytes.

## Implementation and remaining work

`src/sidebar.zig` builds sidebar rows and discovers conventional server sockets. `src/main.zig` owns rendering and interaction. `src/backend.zig` polls tmux on a worker and handles navigation requests. `src/model.zig` handles length-prefixed records, client identity, and agent detection. For `--shell`, `src/pty.zig` opens a pty and starts a child on it as its controlling terminal, and `src/region.zig` pairs a libghostty-vt terminal with that pty and blits its grid into a libvaxis window.

All requests stay within the selected server. Display identity includes tty/name, PID, and creation timestamp. Disconnects require explicit selection again. Failed refreshes retain the previous snapshot and display the tmux diagnostic.

Reads span several commands, and client revalidation is separate from mutations, so topology can change between them. libtmux does not yet expose command deadlines. Persistent display registration, focus hooks, durable completion storage, broader agent support, and event-driven refreshes remain follow-up work. No hooks or layout changes are installed.

## TODO

- [ ] Add an agent status reporting interface and hook integrations, starting with Claude and Codex where supported. Agents should report working, waiting for input or approval, turn completion, and exit, tied to the tmux pane and agent run identity. Prefer explicit hook events over screen inference; keep screen detection as a fallback. Handle stale events and agent restarts, preserve existing user hooks, and keep completion acknowledgement separate from reported status. Investigate available lifecycle hooks before choosing the transport or event format.

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE). Third-party attribution and license information are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
