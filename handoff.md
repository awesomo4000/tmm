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
   module (escape parsing + terminal/screen state, no rendering, no input). It
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
  (robust for any byte). There is no separate raw key channel.
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
- libghostty-vt (the `ghostty-vt` Zig module, upstream PR #8840): escape parsing
  + terminal state + screen state only; **no rendering, no input**. API is
  "extremely not stable" — **pin a revision** in build.zig.zon and expect churn.
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

## 3. What's done (branch `control-mode-compositor`, commit 454186f)

Verified with Zig 0.16.0 (`pip install ziglang` provides the compiler as
`python3 -m ziglang`). Both new modules import only `std`, so they test
standalone without the libtmux/vaxis deps.

- **`src/control.zig`** — control-mode protocol client. Pure/borrowing like
  `model.zig`:
  - `Event` tagged union (output, extended_output, layout_change, window/session
    notifications, pane_mode/pause/continue, client_session_changed/detached,
    paste-buffer, subscription_changed, exit, reply_begin/line/end, unknown).
    String fields borrow from the fed line — copy what you keep.
  - `Parser.feed(line) Event` — one event per line; tracks `%begin`/`%end`/
    `%error` guard depth (nesting-safe).
  - `decodeAlloc(alloc, escaped) ![]u8` — reverses `\ooo` octal escaping.
  - `Command` — `refreshSize`, `refreshWindowSize`, `sendKeysHex`, `capturePane`
    (format tmux command lines to write to the control client's stdin).
  - 11 tests.
- **`src/layout.zig`** — classic v1 layout-string parser → `[]PaneRect`
  (`{id: ?u32, x, y, w, h}`), leaves in document order; strips the checksum,
  replicates the pane-id/sibling look-ahead. 7 tests.
- **`src/model.zig`** — test aggregator now pulls in control.zig + layout.zig.

Test run: `python3 -m ziglang test src/model.zig` → **28/28 pass** (6 model + 3
status + 11 control + 7 layout). Nothing existing broken.

> Note: `zig build test` can't run in a network-restricted env because it must
> fetch libtmux + vaxis from GitHub. Test the new std-only modules directly:
> `zig test src/control.zig`, `zig test src/layout.zig`, or the aggregate
> `zig test src/model.zig`.

---

## 4. Remaining plan (phased)

Each phase is independently testable with the `regress/`-style shell harness or
unit tests. Estimated ~2.5–3.5k new/changed Zig total; current tmm ~1.4k.

**Phase 2 — transport + model-from-events** (~800–1100 LoC)
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
- Read image data from libghostty-vt (API per Ghostling's renderer — read it
  first), re-emit kitty to ghostty positioned/clipped per pane rect. Accept
  live-only semantics (no pre-attach image restore).

**Phase 5 — hardening**
- Flow control (`%pause`/`%continue`, the 300 ms `CONTROL_MAXIMUM_AGE`
  backpressure), reconnect, multi-window, resize-storm debounce for heavy panes.

**Deferred (not v1):** remote aggregator (host dimension), multi-backend
(screen/zellij), patched-tmux image persistence (#5445), static-pane-inside-tmux.

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
