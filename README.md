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

Images a program draws are shown. A kitty transmission is parsed and stored by the region's terminal, and the parser publishes where each placement sits along with the render state; the draw then hands the pixels to the outer terminal once per image and places them every frame, because libvaxis keeps a placement only for the frame it was drawn in. Transmission is what costs -- every pixel goes down the real terminal -- so it happens once and is cached against the storage generation, which moves when image data or the set of placements changes and deliberately does not move for a scroll.

The pixels are base64 encoded on the way out. The protocol carries the payload inside an APC, so a pixel that happens to be 0x1b would end the sequence in the middle of the image; `transmitPreEncodedImage` writes what it is given, and the encoding is the caller's job.

Placements pinned to the screen are drawn, and so are relative ones. A relative placement (`P=`/`Q=` with `H=`/`V=`) has no position of its own: it hangs off a parent, and the chain resolves to the root's pin plus the cell offsets of every link, which is also what makes it follow the parent through a scroll since a pin moves with the content. A chain rooted at a virtual placement has no resolvable position and is skipped, as is an offset that would take a placement off the top or left.

A virtual placement is not drawn, and that measurement has now been taken. `tools/image-emission.py` runs `kitten icat`, `timg` and `chafa` under a pty that answers as a kitty-class terminal, in three layers -- on their own, inside tmux, and inside a tmm region -- and classifies every byte. Outside tmux the three disagree: icat and timg transmit an ordinary pinned placement, chafa uses placeholders even there. Inside tmux all three switch to virtual, because placeholder cells live in the multiplexer grid and so survive being moved and scrolled by it, which an absolute placement does not. tmm composites through tmux, so virtual is not an edge case here: it is the path every viewer measured takes. The declared extent cross-checks the counting -- `c=` by `r=` cells per draw, a whole number of redraws per capture.

Drawing one means scanning every cell each frame, decoding the diacritics that encode the row, the column and the image id, grouping contiguous runs into rectangles and asking the storage which image each refers to, inside a blit that is 0.25ms and worth keeping there. The diacritics are indices into a fixed 297-entry table, not offsets from a base codepoint.

Nothing shows an image inside a tmm pane today regardless, and placements are not the reason. A program in the region sees `0x0` pixels from `TIOCGWINSZ`, because tmux propagates the pixel geometry of a tty client and tmm attaches as a control client, which has none to report. The query route is unanswered too: libghostty-vt reports `CSI 14 t`, `CSI 16 t`, `CSI 18 t` and mode 2048 through a `size_report` effect with a `size_report.encode` helper to format the reply, and `src/surface.zig` does not wire it. So every viewer concludes the terminal has no graphics and emits text -- icat says so outright, the others fall back silently. Answering `size_report` from the region geometry and the outer terminal's cell size comes before virtual placements, and neither alone puts an image on the screen.

Formats other than RGB and RGBA are left undrawn rather than guessed at. Without `--shell` nothing changes: no pty is opened and no terminal is created.

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

Every reader of a pane holds the compositor's lock for as long as it uses the pane, and not merely to look it up. The event worker frees a pane that leaves the layout, so handing a pointer out and releasing the lock first -- which is what the lookups, the blit and the cursor all used to do -- left the display free to use memory the worker had already freed. Holding the lock delays a layout change, which happens only when a pane appears or goes; the output path still takes it just long enough to find a pane and feeds outside it, and a keystroke through the compositor still costs about 0.19ms under continuous output. Waiting for a crash does not show this: freed memory stays mapped and poisoned, so a stale read yields nonsense rather than a fault, and the window is nanoseconds wide. `tests/pane_use_after_free.py` proves it instead with a sentinel on each pane, cleared just before the free and checked at the use. One binary runs both patterns under the same conditions, the old lookup behind an environment variable with a wait wide enough to observe: the pattern that releases the lock first reports two uses of a freed pane, and the one that holds it reports none, repeatably. The test fails if the old pattern ever stops reporting them, because a clean result then proves nothing. `tests/pane_churn.py` is the broader guard on the fix itself, since holding a lock longer risks a deadlock and risks starving the worker.

A pane that existed before tmm attached is seeded from tmux's own screen with a one-shot `tmux capture-pane`, not over the control stream. `Stream.request` writes a command and then reads the reply that follows, matched by arrival order, and seeding runs on the event worker while the display thread writes keystrokes to the same stdin: a `send-keys` arriving between those two halves makes tmux answer it first, so the request takes the wrong reply block and the capture's own output is left to be parsed as events. Panes appear at human pace, so a fork and an exec there cost nothing, and nothing on the keystroke path is shared. It runs after the lock is released, too: a keystroke needs that lock to find its pane, and waiting for another process while holding it would have made typing wait for a capture. Commands and events are safe on one stream because they travel on different descriptors; only a request, which writes and then reads, is not.

tmux still owns the session, the windows, the processes, the scrollback and the persistence, and still delivers SIGWINCH itself. tmm never resizes a pane.

The session's active window is what gets composited, and a switch is followed. Three things had to be measured rather than assumed. A `%layout-change` names only its own window's panes, so adopting one from another window replaced everything on screen: a split in a background window used to take the display. A window switch arrives as `%session-window-changed` with no layout, because tmux sends a layout when one changes and not when a client starts looking at a window. And attaching reports the session but never which window is active, while sending a layout for every window in it, so whichever arrived last was displayed, which could be a window nobody was looking at.

So the active window is asked for at attach and after a switch, and a window's panes are learned with `list-panes -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'`, which gives the geometry the layout string was being parsed for anyway. Two other routes were tried and rejected by measurement: `refresh-client -l` answers with a bare `%begin`/`%end` and resends nothing, and `#{window_visible_layout}` is JSON in this tmux while `%layout-change` carries the classic checksum form, so one parser cannot read both. Both queries are one-shot subprocesses rather than control-stream requests, for the reason seeding is, and both happen at human pace.

Scrollback is tmm's own, and the wheel reaches it. `%output` carries every byte a pane writes, including the lines that have already scrolled out of tmux's view -- a line gone from tmux's visible grid still arrived here -- so the history shown is this terminal's rather than text recovered from tmux's, and it carries everything the pane wrote instead of only what tmux understood of it. The limit is 4MB per surface, raised from libghostty-vt's 10KB default, which is a screen or two; bounded because the compositor holds one surface per pane and an unbounded history is a leak with a nicer name.

The wheel scrolls it only when the program inside did not ask for mouse reporting. A pager or an editor scrolls its own content, so a terminal that intercepted the wheel would break it, and that is what the encoder decides anyway: with reporting off it encodes nothing and the event had nowhere to go. `tests/scrollback.py` checks all three: a line that left the screen comes back, scrolling forward returns to the live output, and with reporting on the viewport stays put while the program gets the event.

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
mise run test          # the suite
mise run latency       # latency on a quiet machine, with the floors under it
mise run deps-check    # how far behind the vendored libghostty-vt is
mise run clean-tests   # remove what a killed test run left in /tmp
```

The suite cleans up before it starts and runs the latency tests early. Both
matter. The suites create sockets and directories under `/tmp` with
`tempfile.TemporaryDirectory`, which cleans up when a test exits normally and
not when one is killed by a timeout, so iterating on a failing test
accumulates tmux servers and nested tmm processes; 47 directories had built up
across sessions before this was noticed. That distorts what follows: a run
started on a dirty machine reported a 52ms worst-case keystroke where the same
build on a clean one reports 0.4ms, which looked exactly like a regression
from a dependency bump and was not. For the same reason the latency tests run
before the suites that spawn dozens of processes, where they once reported
13ms against 0.3ms standalone. Loosening the budget would have been the wrong
answer: the regression those budgets exist to catch showed a 0.2ms median with
a 29ms worst case, so only the worst case catches it.

`--dump` emits a read-only JSON snapshot without opening the UI. Build before running integration tests. Tests use unique sockets and disposable files under `/tmp`, never the default server. They cover shell and agent pane navigation, client isolation, sidebar mouse input, blink, unusual names and paths, resizing, disconnection, switching servers, failures, and exit. tmm runs inside its own region, which is the shortest statement of how complete the region is: `tests/split_shell.py` nests it three deep and checks that a keystroke typed at the bottom reaches the tmux server. Focus descends by clicking, which rebases the column at each level; F12 does not descend, because every level matches it before forwarding.

A keystroke takes no lock. The parser publishes the encoder's view of the terminal's modes as one atomic word, and `sendKey` reads that snapshot, encodes, and writes to the child. Reading a snapshot one parse behind is not a loss of accuracy: the child has not seen the bytes the parser is working through either, so a key arriving mid-parse genuinely precedes them, and the lock gave the same answer only slower. Compositor keys are formatted into a stack buffer too, because the command used to be built with the allocator once per keystroke.

The draw does not take that lock either. The render state has its own, and the parser publishes into it: the parse lock covers a whole 16KB of output, while the render lock covers one update, about 0.01ms. A draw waiting on it therefore waits for an update rather than for a parse, which is what removes output volume from the latency of a keystroke. The draw's own phase went from 22ms to 0.36ms, and a key under continuous output now costs what it costs on a quiet terminal: 0.1ms median and 0.3ms at worst in `--shell`, 0.2ms and 0.8ms through a tmux pane.

`std.Io.Mutex` is a plain futex with no fairness, so a woken waiter re-races for it and can lose repeatedly, and what a waiter pays follows how much of the time the holder holds it rather than how long any single hold lasts. That is why three lock-side remedies all failed and are recorded in `src/surface.zig`: slicing the parse took the draw's wait from 11ms to 23ms, a parser yield changed nothing, and halving the acquisitions left the frame unchanged because the remaining one grew to fill it. Splitting the state in two is what worked, not tuning the lock.

One semantic change came with it. `RenderState.dirty` means changed since the last update, which was the same as changed since the last draw only while the draw was the one calling update. With the parser calling it, two updates between two draws would report the second as clean and lose the frame, so a `needs_draw` flag is set by the publisher and consumed by the draw.

The far end of every latency measurement is `keyprobe`, built from `src/keyprobe.zig`, not a script. Both ends read `CLOCK_MONOTONIC_RAW` and nothing else, so a reading taken by the harness and one taken by the probe can be subtracted; `keyprobe --clock` is how that agreement is checked rather than assumed, and `--overhead` reports what a reading costs, 19ns mean and 125ns at worst. The plain `CLOCK_MONOTONIC` is not used because it ticks at a microsecond on macOS and 97 percent of back-to-back readings come back identical, which is a poor ruler for a tenth of a millisecond. The probe timestamps on the line after its own `read` returns, before anything is decoded or counted, and writes its records only at exit, because a file write between two keystrokes would be charged to the next one.

It replaced a Python endpoint whose own jitter, one to five milliseconds, was larger than everything being measured. An instrument has to be quicker than its subject or a worst case cannot be told from a hiccup in the instrument, and the first thing the new one showed was an 11ms outlier the old one had been hiding.

`tests/keylag_native.py` takes the interpreter out of the timed path at both ends. `keylag.py` reads the clock in Python and then calls `write`, so a deschedule in between lands in the figure and reads as latency in tmm; here `keyprobe --send` writes the keys and records when each one left, a second probe inside the region records when each arrived, and Python only opens the pty and compares the two logs. Over 3000 samples it gives medians of 0.06ms to 0.17ms, a worst case of 4.4ms once and otherwise under 1.4ms. The same harness against a bare pty, with nothing of tmm in between, gives a median of 0.019ms and nothing at all over a millisecond, which is the cleanest statement of the platform floor and about twice as good as the Python sender could measure.

One thing that harness teaches, at the cost of having briefly believed it: a record is one `read`, and a read can return several bytes, so a record is not a key. Pairing records to keys shifted every pair after the first coalesced read, and a shift of one pairs a key with the next key's send time, manufacturing an error the size of the gap between keys. Four of ten runs appeared to show a multi-millisecond tail in tmm that was entirely this. The control was there to be read the whole time: the same harness on a bare pty showed nothing, which points at the pairing rather than at the program. A more precise clock does nothing for a wrong subtraction.

Two floors sit under the product figures, and both are measured rather than assumed. `tests/tmux_floor.py` is the cost of tmux alone on the `send-keys` path, with tmm not involved: 0.09ms median and 0.18ms at worst while 110MB of output is drained. `tests/pty_floor.py` is the machine's own cost, a byte written to a pty and read by the process on the other end with nothing in between: 0.020ms median and 0.04ms at worst. Against those, tmm adds about 0.09ms on either path.

They run on their own, with `mise run floors`, and not as part of the test task. Neither asserts anything -- they are reference measurements of the machine and of tmux, not regression tests of tmm -- so they do not belong in a suite whose job is to pass or fail.

A floor is the cost with nothing in the way, so it is only worth reading on an idle machine. One run inside the test task reported a 28ms sample where the same test alone reports 0.04ms, which is what prompted the split, but that has not been reproduced: not by running the floor straight after the whole suite, nor by running it straight after the 110MB drain of the tmux floor, nor under twelve busy processes, which moved the scheduler jitter only from 0.29ms to 0.63ms. It looks like one instance of the same sporadic wakeup cost that shows up everywhere else in these measurements, rather than something the suite did.

So each floor prints the machine's scheduler jitter for context and says plainly when a reading is not a clean floor: any sample over a millisecond means something else was running, and the number then says more about that than about the floor. There is deliberately no threshold on the jitter, because none could be justified by what was measured. The warning has been exercised directly rather than observed firing on its own.

Every layer is quicker under load than idle, and that is the whole explanation for the occasional millisecond outlier. Waking a process that has been sitting idle costs more than handing a byte to one that is already running, and it shows up on the bare pty too, where neither tmm nor tmux exists. It is the scheduler, so no amount of keeping tmux warm would touch it: the process being woken is the program the keystroke is for, and tmm cannot keep that one warm without writing to its input.

A program in the region can say what it is doing, and tmm listens. OSC 7501 program status, revision 0.4: a report is `OSC 7501 ; state=working:id=build:progress=40 ST`, and `OSC 7501 ; ?` asks whether the terminal supports the protocol at all. Answering that query is not optional politeness -- a program that gets no reply is specified to treat the protocol as unsupported, which is exactly what tmm said while the effect hook was null.

Records follow the specification where it is specific. A report replaces its record completely, so a key the program stopped sending is a value removed rather than one that persists. An `id` is a path, so `build/link` is a child of `build`, and root and child records coexist: a root can be idle while a child is blocked. `state=clear` removes the addressed record and every record beneath it, or every record when no id is given. Text arrives base64 and is copied, because the parser's buffers live only for the length of the callback. Two hundred and fifty six records are kept and the least recently updated goes after that.

A record's lifetime is tied to the shell prompt, which is why the prompt is observed too. A new prompt (OSC 133 A) ends whatever the last command was doing, so the records it left for work in progress go, while `done` and `error` stay, those being the two a user has not looked at yet. Without that a program which exits mid-task leaves a `working` record claiming it still runs, which is a stale indicator that never clears.

The records have their own lock rather than the parse lock, so reading them never waits on the parser. `TMM_INPUT_LOG` records each report, which is how `tests/program_status.py` checks the capture without a display: it also asserts the query is answered, since that is what a program decides support from.

A report reaches the sidebar in compositor mode, where tmm is the terminal for each pane and can see it. The row shows the reported indicator instead of the inferred one, with the percentage for a `working` report that carries progress and the reason for a `blocked` one: `● sh 40%`, `! sh (permission)`, `✗ sh`. `error` has no screen-detectable equivalent at all. The unread `✓` is not added to a reported state, because that mark exists for an inferred completion that may be stale and a report is current by construction.

The specification leaves aggregation to the terminal, so the rollup is a choice. A pane may hold a root record and children while a row shows one state, so the most urgent wins: blocked, then error, then working, done and idle. Among equals the most recently updated wins, so a running task's progress is the figure that moves. The reason to show this at all is to notice a pane that needs attention, which is what that order serves.

What this replaces is guesswork. Agent status is currently inferred from a pane's screen, and the detector says so itself: quiet output is never a completion, transitions entirely between polls can be missed, and an unrecognised screen stays unknown. A pane that reports `state=blocked:kind=permission` is the `!` indicator with nothing inferred.

Nothing emits this yet, which is the remaining work and it is not tmm's: an agent needs a hook at its own event callbacks. The integration is one escape sequence, so `tests/sidebar_status.py` stands in for an agent with a one-line `printf` and asserts what the sidebar draws. In the default mode, with no terminal of its own, tmm cannot observe any of this and falls back to the screen detector.

`tests/keyscope.py` is a key scope to run by hand: it blasts the screen and lists every key that arrives through it, with the raw bytes in hex, a description in words, the codepoint, the modifiers held, which encoding it came in (a raw byte, a legacy CSI, SS3, or the kitty CSI u form), the associated text, and the gap since the previous key. Run it bare in a terminal first to see what that terminal does on its own, then run it inside the region and compare, because most of what it measures belongs to the terminal and the keyboard rather than to whatever sits between them. F1 toggles the blast, F2 cycles the kitty flags, F3 resets the statistics, F10 quits; ctrl-c quits only when pressed twice, so that a single one stays inspectable. `--self-test` checks the decoder against known sequences with no terminal at all, and is what the test task runs.

Three numbers, measuring three different things. The gap between arrivals is delivery jitter when a key is held, because the terminal repeats at a fixed cadence: it is what exposes a loop dispatching one key per redraw, which quantises the gaps to a frame. A hold is press to release for one key, which needs the kitty event-types flag. The echo is a DSR cursor query timed until the reply, and the reply is written by whatever is emulating the terminal, so inside tmm it measures tmm's own parse path and the lock a keypress contends for. What no program in that position can measure is the time from the key going down, because nothing in the bytes says when it was pressed; that needs a sender with a clock, which is `tests/keylag.py`.

Key releases reach the program inside. libvaxis asks for kitty flags 29 by default, which omits the event-types bit, so the terminal would report presses only and nothing downstream could deliver what was never received; tmm asks for 31 instead. A release is forwarded with no check on what the program inside turned on, because the encoder drops one unless that program asked for event types too, so a program wanting presses only is unaffected. A release carries no text: it is the key coming up, not the character it produced going in. F12 moves focus on the press, and the release that follows is dropped rather than delivered to a program that never saw the press.

`tests/key_release.py` holds that, and has to emulate the outer terminal to do it: it honours the flags tmm pushes and then sends a release the way a kitty-capable terminal would. It checks that tmm asked for the event-types bit at all, and that a press and a release of both a text key and a bare modifier reach the program. The modifier is the interesting half, since it is reported only under the all-as-escape-codes flag, and mishandling it is what once inserted a blank-looking U+E061 into vi.

`tests/keylag.py` measures what the program inside actually waits: the harness reads the monotonic clock immediately before writing a key byte into tmm's pty, and the child reads it again the instant its own `read` returns, which makes the difference pure delivery latency with none of the harness in it. It is measured quiet and against a child writing continuously, because only the loaded case ever regressed. The child's stdout is nonblocking and drops EAGAIN, so a latency it reports is time tmm took and not time the child spent stuck in `write`. The loaded figure includes however fast the harness itself drains tmm's output, so treat it as an upper bound.

`tests/reconcile_stress.py` churns panes with no settle between operations, which is what it takes to hit the window the gentle oracle almost always misses: the one divergence that prompted it took six suite runs to appear and never reproduced in forty isolated ones, while the stress version diverged in two of three runs against the code without the guard and none of five with it. The race was in the check rather than the model. The collector drains events, applies them, runs a full query, then compares; a pane created during that query is in the query and not in the model, and the model is not dirty, because the event saying so is still in the queue. `State.isDirty` answers whether the model knows it is stale, which it cannot when the news has not been delivered, so the collector now also notes a counter of queued notifications before the query and skips the comparison if anything arrived while it ran.

`tests/split_shell.py` covers `--shell`: the divider geometry, focus, keys reaching the child, the child's output reaching the display, a real `tmux attach` inside the region at the region's exact size, a click and a wheel event inside it moving that client's pane and entering copy mode, box drawing surviving a redraw it took no part in, three levels of nested tmm, and divider drags resizing both sides. Display assertions go through `tests/screen.py`, which replays the cursor, because libvaxis emits only the cells that changed and a rendered line does not appear contiguously in the output bytes.

## Implementation and remaining work

`src/sidebar.zig` builds sidebar rows and discovers conventional server sockets. `src/main.zig` owns rendering and interaction. `src/backend.zig` polls tmux on a worker and handles navigation requests. `src/model.zig` handles length-prefixed records, client identity, and agent detection. For `--shell`, `src/pty.zig` opens a pty and starts a child on it as its controlling terminal, and `src/region.zig` pairs a libghostty-vt terminal with that pty and blits its grid into a libvaxis window.

All requests stay within the selected server. Display identity includes tty/name, PID, and creation timestamp. Disconnects require explicit selection again. Failed refreshes retain the previous snapshot and display the tmux diagnostic.

Reads span several commands, and client revalidation is separate from mutations, so topology can change between them. libtmux does not yet expose command deadlines. Persistent display registration, focus hooks, durable completion storage, broader agent support, and event-driven refreshes remain follow-up work. No hooks or layout changes are installed.

`mise run deps-check` reports how far behind the vendored libghostty-vt is, lists only the commits that change what tmm can parse or emit, and checks the capabilities tmm is waiting on. One of those is the embedder hook for **OSC 3008 hierarchical context**, a UAPI specification for which component currently controls the terminal: a context is pushed when something takes over and popped when it finishes, so ssh, sudo, a container and a shell nest as a tree. libghostty-vt parses it already but `stream_terminal.zig` has no effect for it, so the terminal drops what it parsed and an embedder cannot see it. tmm wants it for what it cannot otherwise know: `type=remote` with `targethost` names the host behind an SSH connection, which the sidebar currently labels only "SSH", and `elevate` marks a pane running with raised privileges, which no amount of reading a prompt gives reliably. The check carries a canary, a hook tmm already uses, so a run that finds nothing proves the check still works rather than that nothing is there.

## TODO

- [ ] Answer `size_report` in the region. A program inside a pane sees `0x0` pixels and no reply to `CSI 14 t`, so every image viewer measured falls back to text. The reply needs the outer terminal cell size, which the real terminal will give for `CSI 16 t`, times the region geometry tmm already computes. Nothing graphical works in a pane until this does.
- [ ] Draw virtual placements, which `tools/image-emission.py` shows is the path every viewer takes once tmux is in it. Scan cells for U+10EEEE, decode the row, column and id from the 297-entry diacritic table, group contiguous runs into rectangles. The budget to respect is the 0.25ms blit, so the scan wants a cheap reject for the common case of a screen with no placeholders in it.
- [ ] Report status from agent hooks, now that the terminal half is done. OSC 7501 is parsed, kept and shown in the sidebar, so what is left is emitting one sequence from the lifecycle callbacks of each agent -- Claude, Codex, omp, pi -- tied to the pane and the run identity. `tests/sidebar_status.py` is the reference for the wire format. Handle stale events and restarts, preserve existing user hooks, and keep completion acknowledgement separate from reported status.

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE). Third-party attribution and license information are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
