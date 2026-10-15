# tmm control-mode compositor — implementation handoff

Audience: a coding agent (or future me) taking this to the terminal. tmm already
exists and is used daily as a tmux sidebar controller. This handoff covers the
new work: turning tmm into a **control-mode compositor** that renders tmux panes
itself (via libghostty-vt) so the right-hand region is a real terminal with
kitty-graphics support, over SSH, with tmux kept as the state/persistence
backend.

Everything below was decided in a long design session and partly implemented +
tested. Treat the decisions as settled unless you find a concrete reason to
revisit; the rationale is included so you don't relitigate.

---

## 0. One-paragraph goal

Local terminal (ghostty) runs `tmm`. tmm draws a left **sidebar** (the existing
controller UI) and renders the rest of the screen as a terminal region. The
region's content is a tmux session's panes, obtained over tmux **control mode**
(`tmux -C`) and rendered by tmm using **libghostty-vt** (the Zig VT engine) +
**libvaxis** (drawing). tmux — local or remote over SSH — owns sessions,
windows, panes, processes, scrollback and persistence. tmm owns rendering,
input routing, and the sidebar. This gives per-pane kitty graphics through a
**stock** remote tmux (the reason control mode beats plain attach), seamless
detach/reattach (tmux persists; tmm re-derives), and a controller UI that is a
pure projection of tmux state.

---

## 1. Architecture decisions (settled) + why

1. **tmux is the source of truth; tmm is a stateless projection + controller.**
   Every tmm action maps to a tmux command (`switch-client`, `new-session`,
   `kill-pane`, `send-keys`) or a system call. tmm never becomes the only place
   a fact lives. On attach, tmm reconstructs everything from tmux — no tmm-side
   persistence needed (no dtach, no state file for core state).

2. **Control-mode compositor, not the attach method.** Two ways tmm could show
   tmux:
   - *Attach method*: run `tmux attach` in a pseudoterminal, render that one
     composited grid. Simple (one VT instance, no protocol), but tmux owns
     rendering → no per-pane UI, tmux's status bar is in your region, and
     **kitty is eaten by tmux's parser**.
   - *Control-mode compositor (CHOSEN)*: `tmux -C`; tmm gets per-pane `%output`
     + `%layout-change`, renders each pane itself with one libghostty-vt
     `Terminal` per pane. More code, but kitty works on stock tmux and per-pane
     awareness/control is natural.
   The deciding requirement was **kitty in agent panes and on remote boxes**
   (porting work). Only control mode delivers that without patching tmux.

3. **libghostty-vt per pane + libvaxis for output.** libghostty-vt is a Zig
   module (escape parsing, terminal/screen state, input *encoding*, and a
   render-state API for custom renderers; it does no drawing itself). It
   fully implements the kitty graphics protocol and exposes image data to
   embedders. libvaxis does the cell drawing tmm already uses.

4. **Single-host scope for v1.** One tmm per tmux; multiplicity via the terminal
   emulator's own tabs/windows. NO remote aggregator (one list across many SSH
   hosts) — deferred and purely additive later (adds a `host` dimension on top
   of the existing model + an SSH control-mode transport; nothing built now gets
   thrown away). Rationale: the user's remotes are for cross-OS dev/build, not a
   parallel agent fleet, so aggregation isn't worth it yet.

5. **Bind to tmux; do not build a multiplexer abstraction.** No
   screen/zellij/dtach backend layer (YAGNI — only pays off with a second rich
   backend, which doesn't exist here). The only discipline: keep tmux-specific
   command strings behind one module so a future backend is a later refactor,
   not a rewrite.

6. **Do not rewrite tmux.** The one-client-one-session invariant that motivated
   all this is ~a few hundred lines of consequence; the rest of tmux (~100k
   lines: tty-keys, format language, copy-mode, terminfo, layout, control
   protocol) is terminal-compatibility lore you don't want to re-derive. The
   compositor is the Zig worth writing; tmux stays the content/state backend.

### Invariants to preserve as you add features
- tmux = truth, tmm = projection + control. No action creates tmm-only state.
- Store tmm's *own* config (tab order/labels/groupings) in tmux **user options**
  (`@sidebar_*` on server/session) + session/window names — free persistence,
  shared across displays, zero sidebar state file.
- Agent/process awareness: prefer **explicit reporting** (tmux hooks /
  `@agent_state` user options / control-mode events) over screen scraping;
  scraping is the fallback only. Live status is ephemeral/re-derived; only user
  acknowledgements (receipts) warrant persistence.

---

## 2. Verified facts from tmux source (trust these)

Checked against `tmux/tmux` master `5a820e6` (`next-3.9`, "3.7c→3.8"). File:line
anchors are from that tree.

- **Control mode `%output` carries RAW pane bytes, pre-parser.** In
  `window_pane_read_callback` (window.c ~1631): for each `CLIENT_CONTROL` client
  it calls `control_write_output(c, wp)` (window.c:1653) and only *afterwards*
  `input_parse_pane(wp)` (window.c:1655). `control_write_output` reads straight
  from the pane's raw evbuffer (`window_pane_get_new_data` → `wp->event->input`,
  window.c ~2562). So kitty Application Program Command (APC) sequences reach a
  control client verbatim even though tmux's own screen model drops them. This
  is why the compositor gets kitty from stock tmux.
- **`%output` escaping** (control.c ~826): bytes `< 0x20` and `\` are emitted as
  `\ooo` (three octal digits); everything else literal. Backslash is always a
  4-char escape (no `\\` form). Decode accordingly (`control.zig decodeAlloc`).
- **`%extended-output %<pane> <age> : <data>`** when pause-mode is on.
- **`%layout-change <@win> <layout> <visible-layout> <raw-flags>`**
  (control-notify.c ~80). Control mode delivers the **classic v1 layout string**
  by default; the JSON "new-layouts" format is opt-in (`refresh-client` flag) —
  do NOT opt in. v1 grammar (layout-custom.c, `layout_construct_cell` ~820,
  `layout_construct_v1` ~874):
  `checksum "," cell`, `cell = WxH "," X "," Y [ "," paneid ] [ "{"cells"}" | "["cells"]" ]`,
  `{}` = left-right, `[]` = top-bottom. Pane-id vs next-sibling disambiguation:
  digits after the comma are a pane id **unless** an `x` follows them (then
  they're the next cell's width; rewind). `layout.zig` replicates this exactly.
- **Guard blocks**: command replies are wrapped `%begin <t> <num> <flags>` …
  `%end|%error <t> <num> <flags>` (cmd-queue.c:595/653/655, format
  `"%%%s %ld %u %d"`). Notifications never appear inside a guard block.
- **Size**: `refresh-client -C <w>x<h>` sets the control client's render size;
  `refresh-client -C @<win>:<w>x<h>` sets one window's size for the client
  (cmd-refresh-client.c ~63-100). tmux re-tiles and emits a fresh
  `%layout-change`. tmux (not tmm) delivers SIGWINCH to the pane processes.
- **Input**: control clients send keys via `send-keys -t %<pane> -H <hex...>`
  (robust for any byte). There is no separate raw key channel. Re-measured
  10/15/2026 on stock 3.8: `\x1b[57441;2u` -- a kitty modifier report, which
  tmux itself cannot generate -- arrives in the pane verbatim.
- **Kitty keyboard NEGOTIATION also survives the compositor path**, for the
  same reason graphics do, and this is what makes the keyboard half of the
  goal reachable through a stock tmux. A program enabling the protocol writes
  `CSI > <flags> u`, which is pane *output*, so it arrives raw in `%output`
  and the pane's own libghostty-vt terminal records the flags. tmm then
  encodes keys to those flags and injects them with `send-keys -H`; a query
  needing a reply goes back out through the same `write_pty` effect
  `region.zig` already uses, pointed at `send-keys -H` instead of a local pty.
  tmux never has to understand the protocol: it is a transport both ways.
  Measured on stock 3.8, one `%output` line carrying both halves at once:
  `%output %0 \033[>1u\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\134`.
  Note when checking this by hand that tmux escapes a literal backslash as
  `\134`, so a shell echoing the *source text* `\033[...]` looks deceptively
  like a real ESC byte; only `\033` not preceded by `\134` is the real thing.
- **This is the distinction between `--shell` and the compositor.** With a real
  tmux *client* in the region (`--shell`), tmux is the emulator and the
  keyboard negotiator for its panes, and then tmux is a hard ceiling: 3.8 has
  no kitty keyboard at all (`man tmux`: `extended-keys` is "the equivalent of
  the modifyOtherKeys xterm resource", and `extended-keys-format csi-u` is
  xterm `formatOtherKeys`, not the kitty protocol), and its screen model drops
  images. Measured: a program inside a tmux pane pushing kitty flags left the
  region terminal's flags at 0, so tmux swallowed the push rather than
  proxying it. The requirement is not that tmux leave the input path, only
  that it leave the *emulation and negotiation* path, which control mode plus
  `send-keys -H` achieves while tmux keeps owning sessions and panes.
- **Seeding**: `capture-pane -p -e -t %<pane>` gives text+attributes to seed a
  pane's VT on attach. tmux does NOT model images, so capture-pane carries no
  images → **images are live-only; pre-attach images are lost on reattach**
  with stock tmux. (Patched tmux PR #5445 stores image placements and would
  survive reattach, but requires deploying unmerged tmux to every box —
  rejected for the remote-porting case.)

### kitty / libghostty-vt
- libghostty now **fully implements the kitty graphics protocol** and exposes it
  to embedders. **Ghostling** (the libghostty demo terminal) renders kitty in
  ~270 lines of code — that is your reference for the consumption API. The
  request to expose image data through the **render-state** C API (ghostty issue
  #12111) was **closed as not planned**, so DO NOT design around render-state;
  read Ghostling's renderer for the actual API before writing the image bridge.
- **Sixel is not supported** by ghostty/libghostty and won't be. Not needed here
  (kitty is the target; the user's terminal is ghostty).
- libghostty-vt (the `ghostty-vt` Zig module): escape parsing, terminal and
  screen state, **input encoding**, and a **render-state API built for custom
  renderers**. It does no drawing. An earlier draft said "no rendering, no
  input"; that was wrong on both counts — see section 8. API is "extremely not
  stable", so **pin a revision** and expect churn.
- **Kitty in the compositor is never transparent passthrough.** tmm parses the
  pane's kitty via libghostty-vt, owns the placement, and re-emits it positioned
  + clipped to the pane rect to the real terminal. The real terminal must be
  kitty-capable (ghostty ✓). Over SSH this is fine (escapes + base64 ride the
  pipe). Chain: `agent → tmux %output (raw kitty) → tmm/libghostty-vt
  (cache+place) → re-emit to ghostty in the pane rect`. No wrapper, no
  `allow-passthrough`, no unicode placeholders needed in the control-mode path.

### Alternative (documented, NOT the chosen path)
If you ever keep the simple attach method instead of the compositor, kitty
through stock tmux requires a wrapper that transmits the image via
`allow-passthrough` (position-independent) and places it via kitty **unicode
placeholder** cells (ordinary Unicode that tmux stores/redraws, so placement
survives). Naive passthrough alone fails: `screen_write_rawstring` →
`tty_cmd_rawstring` (screen-write.c ~3190) dumps bytes with no grid entry and no
clipping, so the image is mispositioned and clobbered on the next redraw. The
wrapper only covers programs you wrap (fine for an agent, not for arbitrary
panes). Prefer the compositor.

---

## 3. What's done (on `main`, 10/08/2026)

Toolchain is pinned by `mise.toml` (zig 0.16.0). Run everything with
`mise run test` (unit plus the control-mode suite) or individually:
`zig build test`, `python3 tests/control_mode.py`,
`python3 tests/integration.py`, `python3 tests/measure_spawns.py`.
38 unit tests: control 11, layout 7, model 7, reconcile 8, status 3, vt 2.

**Protocol and parsing**

- **`src/control.zig`** — control-mode protocol. Pure/borrowing like
  `model.zig`:
  - `Event` tagged union (output, extended_output, layout_change, window/session
    notifications, pane_mode/pause/continue, client_session_changed/detached,
    paste-buffer, subscription_changed, exit, reply_begin/line/end, unknown).
    String fields borrow from the fed line — copy what you keep.
  - `Parser.feed(line) Event` — one event per line; tracks `%begin`/`%end`/
    `%error` guard depth (nesting-safe).
  - `decodeAlloc(alloc, escaped) ![]u8` — reverses `\ooo` octal escaping.
- **`src/layout.zig`** — classic v1 layout-string parser → `[]PaneRect`
  (`{id: ?u32, x, y, w, h}`), leaves in document order; strips the checksum,
  replicates the pane-id/sibling look-ahead.

Both validated against live tmux 3.7c, not just fixtures: real `%layout-change`
strings parse to correct rects, and a real `%output` line round-trips to exact
bytes with a kitty APC intact.

**Transport**

- **`src/cmstream.zig`** — owns a long-lived `tmux -C attach` child and turns
  stdout into a stream of `control.Event`. `request`/`requestArgv` run a tmux
  command over that same client and return its guarded reply, so a query costs a
  write and a read instead of a fork and exec. `open` drains the guard block
  tmux emits for the attach itself, without which the first request matches that
  block and returns the wrong result. Notifications arriving while a reply is
  outstanding are deferred and replayed by `next`.
- **`src/cmprobe.zig`** + **`tests/control_mode.py`** — a probe that prints each
  event as `control.zig` classifies it, and an integration suite that drives a
  disposable socket and asserts the stream. Also exercises `request`.

**Event-driven collector**

- `Shared.wake` (a cancellable `std.Io.Semaphore`) replaced the collector's
  fixed 500 ms `io.sleep`. `backend.controlWorker` reads the event stream and
  posts that semaphore on structural events, throttling `%output` to one wake
  per 500 ms. `Shared.send`/`blinkDisplay`/`renameSession` post it too, since
  they hand work to a collector that no longer polls for it.
- `backend.heartbeatWorker` still posts every 500 ms as a floor. **This is
  scaffolding**: agent completion needs two consecutive idle samples and an idle
  agent emits no output to trigger the second. It goes away when `status.zig`
  derives agent state from live `%output`.

**Queries off subprocesses**

- `backend.queryRead` sends read-only, program-fixed commands over the query
  client. Converted: `list-clients`, `list-sessions`, both `list-panes`, both
  `display-message` reads, and `capture-pane`. Mutations and anything carrying
  user data deliberately stay on the argv path — a control-mode command is one
  text line, tmux parsing treats `#` as a comment and `;` as a separator, and
  there is no escape for a single quote inside single quotes, so `requestArgv`
  refuses an unquotable argument rather than mis-parsing it.
- Measured by `tests/measure_spawns.py`: six seconds of the real TUI, at least
  twelve collects, **two** tmux spawns total, both the persistent control
  clients. Previously that window was roughly eighty-four spawns.
- Two control clients, not one: `request` cannot safely interleave with `next`
  on the same stream, so the event reader and the query channel are separate
  tasks with separate clients. Both are excluded from the display list by the
  existing `client_control_mode` filter.

**Groundwork for the rest**

- **`src/reconcile.zig`** — compares an incrementally maintained view against a
  freshly queried one, order-insensitively. Compares **identity and membership
  only**: which sessions and panes exist, each session's name and path, each
  pane's session and window.
- **`src/state.zig`** — the incremental model: owned sessions and panes, a dirty
  set of windows and sessions, and a `needs_full` escalation. Events either
  update it directly (`%window-close` removes, `%session-renamed` renames) or
  mark something dirty, because notifications carry only ids.
- **Wired in**: `Shared` queues notification lines as owned copies (payloads
  borrow from the read buffer), capped, with overflow forcing a resync.
  `controlWorker` pushes, the collector drains and applies, then compares
  against the full query and adopts it. **The full collect is still
  authoritative** — the incremental model is observed, not yet trusted, while
  the apply logic is proven. `tests/reconcile_live.py` drives nine churn
  operations against the running app with `TMM_RECONCILE_LOG` set and fails on
  any divergence; currently zero.

### Found by the oracle: cwd and command are not event-derivable

The first run reported `pane_differs %5: command queried=sleep
incremental=bash`. That was not a bug in the apply logic but a wrong assumption
in the oracle: **tmux emits no notification when a pane's working directory or
foreground command changes.** They shift silently whenever the user runs
anything, so an event-driven model cannot track them and comparing them reports
divergence on the first command typed.

Consequence for the plan: `cwd`, `command` and agent status are **sampled
properties**, in the same category as each other and distinct from structure.
Events can maintain *which panes exist and where*; properties need a periodic
query regardless. So the heartbeat does not disappear entirely — it shrinks from
a seven-query full rebuild to one cheap `list-panes -a -F` property refresh over
the control client, plus agent status. Plan Phase 2 accordingly.
- **`src/vt.zig`** — per-pane `Terminal` wrapper, sets a non-zero
  `kitty_image_storage_limit`, and pins the kitty-graphics and OSC 7501 parsers
  as *tests* so a dependency update that loses either fails loudly.
- **`vendor/libghostty-vt-source.tar.gz`** — libghostty-vt vendored as its
  release archive and referenced by relative path, replacing a git dependency on
  the whole ghostty repository (4 MB in the repo versus 107 MB unpacked). See
  `vendor/README.md` for the exact commit and the update procedure.

---

## 4. Remaining plan (phased)

Each phase is independently testable with the `regress/`-style shell harness or
unit tests. Estimated ~2.5–3.5k new/changed Zig total; current tmm ~1.4k.

### Phase 2 groundwork done (10/07/2026)

`src/cmprobe.zig` + `tests/control_mode.py` validate the parser against a live
tmux before `backend.zig` is restructured. The probe spawns `tmux -C attach`
with piped stdio, feeds each line to `control.Parser`, and prints one classified
event per line; the harness drives a throwaway `-S` socket and asserts the
stream. Run with `zig build cmprobe -- -S <socket> -t <session>` or
`python3 tests/control_mode.py`. Deterministic across repeated runs:

```
reply_begin 285 / reply_end 285 ok     guard block pairs by number
session_changed $0 alpha               session ids really are "$N"
window_add @1 / window_renamed @1      window lifecycle
layout_change @1 419a,80x24,0,0[80x12,0,0,1,80x11,0,13,2]
output %2 HELLO-FROM-PANE\x0d\x0a       decoded to exact bytes, CRLF intact
exit                                   on kill-server, stream ends cleanly
```

**Three Zig 0.16 traps found doing this; Phase 2 will hit all three.**

1. **`takeDelimiterExclusive` leaves the delimiter in the buffer.** It is
   `peekDelimiterExclusive` plus `toss(result.len)`, and the returned length
   excludes the newline — so the next call sees a leading delimiter, returns a
   zero-length slice and tosses nothing. Paired with an `if (line.len == 0)
   continue` guard that is a silent infinite spin, which looks exactly like a
   blocked read. Use `takeDelimiterInclusive` and trim `"\r\n"`.
2. **`Child.kill()` reaps the child and clears `child.id`**, so a following
   `wait()` trips `assert(child.id != null)` and panics. Use one or the other.
3. **`File.reader()` defaults to positional reads**; a control-mode child is a
   pipe, so use `readerStreaming()`. (This was not the cause of the hang above,
   trap 1 was, but positional reads on a pipe are wrong regardless.)

When a line-reader looks like it is blocking, read the fd directly first: a
single `readStreaming` returning several whole lines proves the transport is
fine and the bug is in the line splitting.

**Phase 2 — transport + model-from-events** (~800–1100 LoC) — *transport,
event-driven collector and the query cutover are done; what remains is the
incremental model itself*
- New transport: spawn `tmux -C attach` locally, or `ssh <host> tmux -C attach`
  remotely, as a long-lived child (it's a persistent REPL: write commands to
  stdin, read `%`-notifications + `%begin/%end/%error` replies from stdout).
  Use tmm's existing `std.Io` patterns (see backend.zig; it already uses
  `std.Io.Mutex`, worker model).
- Feed each stdout line to `control.Parser.feed`; dispatch events.
- Drive `model.zig`'s session/window/pane tree from `%window-*`/`%session-*`/
  `%layout-change` instead of poll snapshots. Keep the poll path only for socket
  discovery / fallback.
- `backend.zig` is the big change: steady state becomes event-driven.

**Phase 3 — compositor (text)** (~700–1000 LoC)
- **VT lifecycle is tmm's to manage.** Allocate on first sight (initial
  enumeration at attach, then `%window-add` / a `%layout-change` revealing a new
  pane id) and destroy on pane death (`%layout-change` without that pane, or
  `%window-close`). Missing the teardown leaks a whole terminal, its scrollback
  and its image store per closed pane.
- **Memory multiplies by pane count.** `vt.zig` currently sets
  `default_kitty_storage_limit` to 16 MiB per pane, which is a 320 MiB ceiling
  across twenty panes, before scrollback. Make it a budget shared across panes,
  or much smaller per pane, before a session with many agents exists.
- Each VT must be resized from `layout.zig`'s rects on every `%layout-change`;
  `refresh-client -C <w>x<h>` is what makes tmux re-tile and emit a fresh one.
- One `libghostty-vt` `Terminal` per pane (new `vt.zig` wrapper); feed decoded
  `%output`; resize per `%layout-change` (parse with `layout.zig`).
- Render: for each visible pane, blit its libghostty grid into the pane's rect
  within the right region (offset by sidebar width) via libvaxis. Draw your own
  borders/chrome (no tmux status bar). New `compositor.zig`.
- Focus model + input routing: keys/mouse over a pane → `send-keys -H`; mouse
  hit-test to pane rects; divider/terminal resize → `refresh-client -C`.
- Seed each pane with `capture-pane -p -e` on attach.
- `main.zig` gains the compositor render path + focus/input.

**Phase 4 — kitty image bridge** (~150–350 LoC)
- Read image data from libghostty-vt (API per `include/ghostty/vt/kitty_graphics.h`,
  see section 6), re-emit kitty to ghostty positioned/clipped per pane rect.
  Accept live-only semantics (no pre-attach image restore).
- **The response leg.** Kitty is request/response: an app transmits an image and
  may wait for `\x1b_G...;OK\x1b\\`, and `a=q` is a direct question. In a
  compositor the real terminal's reply goes to tmm, not the app, so **tmm must
  synthesise the response itself**. Without it, apps that wait will stall or
  conclude kitty is unsupported. Delivery is verified working:
  `send-keys -t %N -H 1b 5f 47 69 3d 31 3b 4f 4b 1b 5c 0a` put exactly
  `\x1b_Gi=1;OK\x1b\\` into the pane process. libghostty-vt implements the
  protocol, so derive the reply from its state rather than hand-rolling it.
- **Image id remapping.** Every pane's app allocates kitty ids believing it owns
  the terminal, and tmm re-emits into one real terminal, so ids collide. Keep a
  per-pane map `(pane, storage id) -> outbound id`, allocated from a monotonic
  counter **on first sight and reused thereafter** — a fresh id per sighting
  leaks an image per frame and breaks replace (`i=N` re-transmit) and delete
  (`a=d,i=N`). Free on app delete and on pane death. Read ids from
  libghostty-vt's `ImageStorage`, which already resolves the `i=` id versus `I=`
  number distinction (`imageById` / `imageByNumber`), rather than sniffing APCs.
- libvaxis is the emit side: `Image.init(id, w, h)` references an image the
  terminal already knows, so transmit once and place many times, clipped per
  pane rect via `DrawOptions.clip_region` and ordered with `z_index`.

**Phase 5 — hardening**
- Flow control (`%pause`/`%continue`, the 300 ms `CONTROL_MAXIMUM_AGE`
  backpressure), reconnect, multi-window, resize-storm debounce for heavy panes.

**Deferred (not v1):** remote aggregator (host dimension), multi-backend
(screen/zellij), patched-tmux image persistence (#5445), static-pane-inside-tmux.

### Settled 10/08/2026: uniform per-pane VTs

One libghostty-vt `Terminal` for **every** pane, unconditionally, so kitty works
in all cases. No selective allocation, no per-pane fidelity tiers. The
alternatives below are verified to exist and are parked deliberately; revisit
only if memory or throughput becomes a real problem, not pre-emptively.

Parked, with the mechanisms confirmed in `tmux(1)` under `refresh-client -f`:

- `no-output` — a control client stops receiving pane output entirely. Correct
  for the query client, which only runs commands and currently receives every
  `%output` just to discard it (`Stream.discard_notifications`).
- `read-only` — would make the event client's read-only role a tmux-enforced
  guarantee rather than a convention (`controlWorker` makes no send/request
  calls today).
- `pause-after=<secs>` — per-client flow control, already noted for Phase 5.
- Allocating VTs only for rendered panes, with agent status for the rest coming
  from an on-demand `capture-pane`. This is the lever to pull if the per-pane
  memory budget below bites.

### Why not raw per-pane passthrough

Recorded so it is not reconsidered from scratch: a pane's bytes cannot be piped
into a sub-rectangle. A VT stream is stateful and global to the terminal —
absolute cursor positioning, erase-in-display, scroll-region changes, alternate
screen — and terminals have no viewport primitive to scope a stream to a box
(`DECSTBM` constrains vertical scrolling only, with no horizontal equivalent).
Raw output would move the real cursor, clear the window and reset margins,
destroying the sidebar and every other pane. That is why tmux parses into a grid
and re-renders, and why taking its place means inheriting that work.

Kitty is the sole exception, and only because its placements carry explicit
position and clipping — exactly the property that makes re-emission into a pane
rect possible.

### Measured: why control mode rather than a normal client

Same pane emitting the same bytes, on tmux 3.7c:

| client | plaintext | kitty APC |
| --- | --- | --- |
| `tmux attach` (normal) | arrives | **dropped** (no `QUJD`, no `\x1b_G`) |
| `tmux -C` (control) | arrives | `\033_Gf=24,...;QUJD\033\134` verbatim |

756 bytes were captured from the normal client with the plaintext marker
present, so the capture was working; the APC simply is not there. tmux's screen
model has no image concept, so its parser discards the sequence while rendering.

### File map (new / changed)
```
src/control.zig    DONE  control-mode protocol parser + decoder + commands
src/layout.zig     DONE  v1 layout string -> leaf PaneRects
src/vt.zig         new   libghostty-vt Terminal per pane: feed/resize/read grid
src/compositor.zig new   layout rects -> libvaxis cells + kitty re-emit
src/backend.zig    edit  poll loop -> control-mode stream reader; model from events
src/model.zig      edit  tree fed incrementally; per-pane VT handle; (test agg DONE)
src/main.zig       edit  compositor render + focus + input routing + divider/resize
src/status.zig     edit  agent status from live %output (simplify screen scraping)
build.zig.zon      edit  add libghostty-vt (pin a revision)
```

---

## 5. Build / env notes
- Zig 0.16.0 (`minimum_zig_version` in build.zig.zon). If no system zig:
  `pip install ziglang` then `python3 -m ziglang {build,test,...}`.
- Deps today: `libtmux` (awesomo4000/libtmux, pinned) + `vaxis`
  (rockorager/libvaxis, pinned). Add libghostty-vt next.
- Zig 0.16 idioms this codebase uses: unmanaged `std.ArrayList` (`.empty`,
  `.append(alloc, x)`, `.toOwnedSlice(alloc)`, `.deinit(alloc)`); no
  `ArrayList.writer(alloc)` (append manually / `bufPrint`); `std.Io` for
  transport (`std.Io.Mutex`, etc.); `std.mem.splitScalar`/`tokenizeAny`.
- Pure logic lives in std-only modules with inline tests (model/status/control/
  layout); IO/transport lives in backend.zig. Keep that split.

---

## 6. Open decisions — RESOLVED 10/02/2026

Both questions answered by reading the vendored libvaxis 0.6.0 in `zig-pkg/`
and a sparse checkout of ghostty master (`x/prior-art/ghostty`).

### How much does libvaxis already do?

**Cell diffing: yes, don't rebuild it.** `Vaxis.zig` keeps
`screen_last: InternalScreen` and diffs in `render()`. The compositor needs a
grid-to-cell blit, not damage tracking.

**Kitty image OUTPUT: yes, and it fits the compositor exactly.** `src/Image.zig`
has `transmit_opener = "\x1b_Gf=32,i={d},s={d},v={d},m={d};"`, and
`DrawOptions` carries `z_index` plus a `clip_region` ("a clip region of the
source image to draw"). `Image.init(id, w, h)` constructs a placement for *an
image id the terminal already knows*, so tmm can transmit once and place many
times, clipped per pane rect. That is the Phase 4 emit model, already written.

**Kitty image INPUT: no.** libvaxis's terminal widget parses APC and throws it
away — `widgets/terminal/Terminal.zig:765`:
`.apc => |apc| log.info("unhandled apc: {s}", .{apc})`. No image model, no sixel.

**libvaxis's terminal widget cannot substitute for libghostty-vt.** It is 2126
LoC of real VT (Terminal 872, Screen 537, Parser 182) but it is **pty-coupled**
(`pty: Pty` field, `Pty.init` in `init`, `run()` reads the pty) with no
`feed(bytes)` entry point, and it drops graphics. Feeding it control-mode
`%output` would mean patching it. The libghostty-vt decision stands.

### Is the image API reachable? Yes — and Ghostling is no longer the reference.

libghostty-vt is in ghostty master as `src/lib_vt.zig`, which re-exports
`pub const kitty = terminal.kitty`. There is a **dedicated, documented C header**
`include/ghostty/vt/kitty_graphics.h` with a full usage walkthrough, exported
behind `if (features.kitty_graphics)` in `lib_vt.zig:388-400`:

- `placement_iterator_new` / `_set` (z-layer filter) / `_next` / `_free`,
  populated via `ghostty_kitty_graphics_get()` with
  `GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR`
- `placement_get`, `placement_rect`, `placement_pixel_size`,
  `placement_grid_size`, `placement_source_rect` (clamped to image bounds), and
  `placement_viewport_pos` — **viewport-relative grid position, may be negative
  for partially scrolled placements**, which is precisely the clipping input the
  compositor needs
- `ghostty_kitty_graphics_image()` → handle, then `image_get()` for dimensions,
  pixel format, compression and a borrowed pixel pointer
- **Generation stamps** (`GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION`): a
  storage-wide stamp bumped on any transmit/placement/delete, so an unchanged
  stamp lets a frame skip all placement and image work

The earlier note said to design around Ghostling because render-state image
exposure (#12111) was closed as not planned. That is still true of
*render-state*, but a separate first-class kitty-graphics API exists, so read
`kitty_graphics.h` instead. The repo also references an official example,
`c-vt-kitty-graphics/src/main.c`.

### Three build requirements the earlier draft missed

1. **Kitty graphics is feature-gated but defaults ON.** `src/terminal/kitty.zig`
   has `pub const graphics = if (build_options.kitty_graphics) @import(...) else struct {};`
   and `terminal/build_options.zig:165` declares `kitty_graphics: bool = true`,
   forced off only for freestanding targets (`kittyGraphics()`, ~line 274). No
   build wiring needed on macOS — verified by a test asserting
   `@hasDecl(ghostty.kitty.graphics, "ImageStorage")`, which fails to resolve if
   the feature is off.
2. **Image storage is off by default.** A non-zero
   `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` (terminal.h:1774) is required
   or nothing is retained.
3. **A PNG decoder callback is mandatory**, installed via `ghostty_sys_set()` with
   `GHOSTTY_SYS_OPT_DECODE_PNG` (sys.h:165) — libghostty-vt ships no PNG decoder.
   Good news: `zigimg` is already in the dependency graph (`zig-pkg/zigimg-0.1.0`,
   pulled in transitively by vaxis) and can serve as that callback.

Consumers can take the Zig module or link the `ghostty-vt-static` artifact
(build.zig ~160-176); for a Zig codebase the module is the nicer route. The Zig
module is named **`ghostty-vt`** (and `ghostty-vt-c` for the C ABI),
`src/build/GhosttyZig.zig:28`.

### Wiring result (done, 10/02/2026)

Pinned `ghostty_vt` to ghostty `83edd491e3024ae5e50393d62877b8897da1cccd`
(`ghostty-1.3.2-dev`) and imported the `ghostty-vt` module in `build.zig`.

**`simd = false` is required.** Ghostty defaults SIMD on, which links libc++, and
Zig 0.16.0 cannot compile its own bundled libcxx for aarch64-macos:

```
error: sub-compilation of libcxx failed
  .../lib/libcxx/include/__random/clamp_to_integral.h:47:58:
  note: use of undeclared identifier 'INFINITY'
```

The dependency graph itself is fine — wuffs, uucode, simdutf and highway all
build; only the libc++ sub-compilation fails. Passing `.simd = false` to
`b.dependency` makes the module pure Zig, which is also the configuration that
makes it dependency-free. Revisit when Zig ships a working libcxx; the cost is
slower VT parsing, not lost features. Note that kitty graphics still pulls in
**wuffs** (C) for pixel format conversion and alpha blending, so the module is
not literally C-free once graphics are on.

`src/vt.zig` holds the per-pane `Terminal` wrapper and sets
`kitty_image_storage_limit` (requirement 2 above). PNG decoding (requirement 3)
is not wired yet; it is only needed for Phase 4.

### Estimate impact

Phase 4's 150–350 LoC looks right and maybe slightly generous on the emit side
(libvaxis `Image` does placement/clipping; a documented iterator supplies rects),
but add PNG-callback wiring. Phase 3 shrinks slightly — no damage tracking — but
still owns the grid blit, focus and input routing.

### Still settled

- **Wrapper vs control-mode for kitty** — control-mode. Only revisit the
  wrapper+placeholder route if you deliberately keep the attach method.
- **Add libghostty-vt now** — yes, Phase 3, pinned to a revision (API is
  "extremely not stable").

---

## 8. The terminal region: verified integration recipe

Established 10/13/2026 by reading
`~/src/quicktui/vendor/opentui/packages/native/src/embedded-terminal`, which
embeds libghostty-vt for the same purpose, and checking every API against the
copy vendored here. This supersedes earlier guesses about what libghostty-vt
does and does not provide.

### Three objects per terminal

```zig
terminal: vt.Terminal          // the state
stream: vt.TerminalStream      // the parser; owns a handler
render_state: vt.RenderState   // the readout, with dirty tracking
```

- **Feed**: `stream.nextSlice(bytes)` with raw bytes straight off the pty. The
  handler carries a `semantic_failure` flag to check after each feed.
- **Resize**: `stream.handler.resize(.{ .cols, .rows })` — through the handler,
  not the terminal.
- **Render**: `render_state.update(alloc, &terminal)`, then read `row_data`.

### Terminal responses come back through the handler

The handler receives data the terminal owes the *program*: device attribute
replies, cursor position reports, and the kitty and OSC 7501 query responses
that section 4 said tmm would have to synthesise. opentui routes them out
through a `writePty(handler, data)` callback. **We route them; we do not
generate them.** For a local pty that means writing to the master; in the
compositor it means `send-keys -H` to the pane.

### Input encoding is provided

`vt.input` exports `encodeKey`, `encodeMouse`, `encodePaste` (with
`isSafePaste` for bracketed-paste safety) and `encodeFocus`, plus `Key`,
`KeyEvent`, `KeyMods` and size constants. Modifier handling, the kitty keyboard
protocol and SGR mouse encoding do not need writing.

### The blit, with dirty tracking

```zig
if (state.dirty == .false) return;             // nothing changed this frame
const rows = state.row_data.slice();
const row_dirty = rows.items(.dirty);
const row_cells = rows.items(.cells);
for (0..state.rows) |y| {
    if (state.dirty == .partial and !row_dirty[y]) continue;
    // ... draw row ...
    row_dirty[y] = false;                      // the consumer clears row dirt
}
state.dirty = .false;                          // and the global flag
```

Per row, over `cells.items(.raw)`, `.grapheme` and `.style`:

- `raw.codepoint()`, `raw.gridWidth()` (wide cells), `raw.hasStyling()`
- `style.fg(.{ .default = colors.foreground, .palette = &colors.palette })`
- `style.bg(&raw, &colors.palette) orelse colors.background`
- swap fg and bg when `style.flags.inverse`
- text is `raw.codepoint()` followed by each codepoint in `grapheme`
- trailing blanks are trimmed by scanning back for `raw.codepoint() != 0`

Per-row dirty flags pair well with libvaxis's own cell diffing: only changed
rows are walked, and libvaxis then emits only changed cells.

### How opentui vendors it, for comparison

A `.path` dependency on an unpacked tree (`zig-deps/ghostty`, 16 MB) with
`.lazy = true`, transitive deps vendored as paths too, for a hermetic build.
Same version and fingerprint as the tarball vendored here. Ours is the tarball
plus a relative `url`, keeping 4 MB in git rather than 16 MB of tree; theirs
avoids an unpack step. Either is fine.

### Built 10/13/2026: `tmm --shell`

`src/region.zig` is the recipe above, realised. `--shell` splits the window
into the sidebar, a one-column divider, and one `Region`; without it tmm is
byte-for-byte what it was, which is the point of the flag. `--split cols` sets
the starting width. F12 moves focus; dragging the divider resizes both sides.
Covered by `tests/split_shell.py`.

Departures from the recipe, each for a reason:

- **Colors are mapped by source, not resolved to RGB.** `style.fg(...)` and
  `style.bg(...)` resolve against libghostty-vt's *own* default palette, which
  would pin the region to ghostty colors on a terminal themed otherwise.
  Reading `style.fg_color` / `style.bg_color` directly instead keeps `.none`
  as libvaxis `.default` and a palette index as an index, so the region
  inherits the user's theme exactly as the sidebar does.
- **`inverse` swaps fg and bg rather than setting libvaxis `reverse`.** The
  outer terminal would otherwise reverse a second time, against its own
  defaults instead of the colors the child named.
- **Clean rows are only skipped when `dirty == .partial`.** libvaxis keeps its
  own previous-frame screen, so a `.full` redraw has to write every row.
- **No trailing-blank trim.** libvaxis diffs cells itself, so writing the
  blanks costs nothing on the wire and keeps the region from retaining stale
  cells after a resize.

### Two things the recipe did not cover, found by building it

- **The child needs a controlling terminal, not just a pty on its stdio.**
  `std.process.spawn` cannot do this, so `src/pty.zig` now forks and execs by
  hand to call `setsid` and `TIOCSCTTY` in between. Without it `TIOCSWINSZ` on
  the master delivers no SIGWINCH and the child never learns it was resized —
  which makes a draggable divider pointless — and a shell reports "no job
  control in this shell". Verified: after a drag the shell itself reports the
  region's exact size.
- **`std.c.T` on darwin defines `IOCGWINSZ` and nothing else.** `TIOCSWINSZ`
  and `TIOCSCTTY` are computed in `pty.zig` the way std computes its one
  neighbour.

### Built 10/15/2026: the mouse, into the region

`Region.sendMouse` encodes a libvaxis mouse event with
`input.encodeMouse` and writes it to the pty, so the region forwards clicks,
drags and the wheel in whatever mode and format the child selected. Forwarded
only while the region has focus, matching the keyboard. Two non-obvious parts:

- **The encoder works in pixels; give it a one-pixel cell.** It serves a GPU
  surface, so `MouseEncodeOptions.size` wants a screen size, a cell size and
  padding in pixels. Setting the cell to 1x1 with no padding makes a cell
  position already a pixel position, and the screen size the grid size.
  libghostty-vt's own encoder tests use exactly this, so it is the intended
  reading and not a trick.
- **The two button enums disagree on the numbers, so map by name.** libvaxis
  is `left=0, middle=1, right=2` (the wire codes); libghostty-vt is
  `left=1, right=2, middle=3`. Mapping numerically swaps middle and right.
  Covered by a test that fails if the two are swapped.

Smaller notes: libvaxis separates `.drag` from `.motion` and the protocol does
not, so both become `.motion` and the button tells them apart. A wheel click
is a press with no matching release, so it must not be allowed to leave a
button recorded as held — `any_button_pressed` is what decides whether a drag
leaving the region is still reported. `last_cell` is the encoder's motion
dedup and the slot belongs to the caller, so `Region` owns it. Positions are
signed, because libvaxis reports a position off the edge that way and the
encoder wants to know it left the viewport.

The end-to-end assertion is on the server, not the display: with `mouse on`, a
click in the region moves the attached client's pane and the wheel puts it in
copy mode. That holds whatever the blit looks like.

### Fixed 10/15/2026: a bare shift press inserted a blank

Reported as "a space is inserted whenever I hit shift" while typing `:q!` in
vi. The character was not a space: it was U+E061, which renders blank in most
fonts. 57441 is the kitty keycode for left shift.

A terminal that speaks the kitty keyboard protocol reports modifier keys
themselves, and libvaxis asks for `report_all_as_ctl_seqs`, so tmm sees a key
press for shift alone. `input.encodeKey` then re-encodes it from the codepoint
whenever the child has *any* kitty flag set, so vi received `CSI 57441;2 u`.
vi had turned on disambiguation only, which does not include modifier reports,
so it decoded the sequence as text and inserted U+E061 into the command line.

`Region.forwards` drops a modifier-only press unless the child set
`report_all`. libvaxis has `Key.isModifier` for the test. The gate belongs in
tmm because the encoder reports the key either way: in real Ghostty the filter
lives in the layer above the encoder, which tmm is.

Two things this made visible, both worth knowing before touching region input:

- **While the child has kitty mode on, its shell cannot be driven.** A control
  key is encoded as an escape sequence too, so neither Enter nor ctrl+c
  reaches the line discipline. The regression test has the child set and pop
  the mode on its own schedule for exactly this reason.
- **The pty echo is the cheapest evidence of what arrived.** The line
  discipline echoes input with `ECHOCTL`, so `^[[57441;2u` appears on screen
  without needing a program in the region to read anything.

### Fixed 10/15/2026: a lost server reported its Zig error name

`tests/integration.py` failed about half the time on the query-failure case,
and the failure was real rather than a test artifact: killing the server mid
query sometimes showed `WriteFailed` in the sidebar instead of a message.
Which one you get is a race. tmux usually prints "no server running" before
the socket is noticed to be gone, and that diagnostic was preferred; when the
write fails first there is no diagnostic to read and the bare `@errorName`
went to the UI.

`backend.reason` now maps the errors that only mean the socket is gone to
"Server connection lost", and the connection-init path uses the same mapping.
`FileNotFound` is deliberately not in the set: it also covers a missing tmux
binary, which is a different problem.

### `TMM_INPUT_LOG`

One line per key and mouse event, appended: the codepoint libvaxis reported
with its shifted and base-layout alternates, the modifiers, the text, the
physical key we resolved, the bytes sent, and the child's current mode
(`cursor_app`, `modify_other_2`, the kitty flag int). An input bug is always a
disagreement between those, and the log makes the disagreement visible instead
of inferred from how a program inside misbehaves.

It immediately found one: libvaxis reports `text` for a key that produced
text, but a terminal may report a key as a bare `CSI <cp> u` with no text
field at all, and the encoder then had nothing to send, so the key was
swallowed. `Region.keyText` falls back to the codepoint, gated on no modifier
beyond shift being held, because ctrl and alt are encoded from the key itself
and handing the encoder text as well would change what it produces. Modifier
keys are excluded by range: kitty reserves `0xe000`-`0xf8ff` for functional
keys, which is where libvaxis takes its constants from, so a codepoint in
there is a key and never text however printable it looks to a UTF-8 encoder.

Rendering assertions need a screen model, not a search of the captured bytes:
libvaxis emits only the cells that changed, each after a cursor move, so a line
reading `F12 sidebar` arrives as `F12`, `sid`, `bar`. `tests/screen.py` replays
the cursor and is what every display assertion goes through.

### Not yet, in the region

- Kitty graphics are parsed and stored (the storage limit is set) but not drawn.
  That is the Phase 4 bridge.
- Scrollback is not reachable; the region shows the viewport only.
- One region only. Per-pane regions and compositing are Phase 3.

---

## 7. References
tmux (master 5a820e6): window.c (read callback 1631, output tap 1653, raw buffer
2562), control.c (%output encoding 826, guard 523-545), control-notify.c
(layout-change 80), cmd-queue.c (guard 595/653/655), layout-custom.c (parse
820/874), cmd-refresh-client.c (-C 63-100), screen-write.c (set_client_cb gate
137, rawstring 3190), input.c (passthrough dispatch 2618-2680).

Upstream: kitty+sixel in tmux PR #5445 (open, needs damage-rect PR #5516);
tmux kitty tracking issue #4902 (closed in favor of #5445); link-pane #719
(TODO forever — why we don't rewrite tmux's model); hide/unhide pane #3047.
libghostty: ghostty-vt module PR #8840; render-state image exposure #12111
(closed, not planned); Ghostling (kitty renderer reference, ~270 LoC).
