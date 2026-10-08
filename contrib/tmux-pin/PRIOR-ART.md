# Prior art

Seven projects checked out into `x/prior-art/` (gitignored) and read. There is
substantially more prior art than expected, and two of these projects tried the
traveling-pane approach this prototype uses and **abandoned it**. That is the
headline.

| Project | Language | Approach |
| --- | --- | --- |
| [tmux-plugins/tmux-sidebar](https://github.com/tmux-plugins/tmux-sidebar) | sh | Per-window, toggled. No hooks at all. |
| [keaising/tmux-tree-sidebar](https://github.com/keaising/tmux-tree-sidebar) | sh | Per-window, idempotent `ensure.sh` on hooks. |
| [sandudorogan/tmux-pane-tree](https://github.com/sandudorogan/tmux-pane-tree) | sh | Per-window mirror, no `join-pane`. |
| [hiroppy/tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar) | rust | Per-window. Closest to tmm in *purpose*: tracks Claude Code / Codex / OpenCode panes across all sessions. |
| [snirt/agenmux](https://github.com/snirt/agenmux) | rust | **Started with `join-pane`, moved to a daemon + per-window reader panes.** |
| [jlong/shelbi](https://github.com/jlong/shelbi) | rust | **Had a traveling sidebar, ripped it out** (issue #1102). |
| [laat/laatmux](https://github.com/laat/laatmux) | go | Per-window. Issue #42 documents the click/focus trap. |

## The big idea: mirror mode (agenmux)

From `src/sidebar.rs`:

> `run_daemon()`: headless preserved-pane mode — frames go directly to the
> sidebar readers in panes visible to attached clients; keys arrive over a
> FIFO. **The panes never move between windows, so switching causes no
> join-pane reflow (the "bump").**

One daemon renders a single frame; each window holds a cheap *reader* pane that
consumes frames from a per-pane FIFO (`agenmux-frame-<pane>`); keys travel back
over a FIFO. Panes never move, so there is no reflow, no rescue-before-kill, and
no focus-steal. This is the same daemon + thin-client shape that the cost
analysis pointed at, arrived at independently and from the other direction.

Hard-won details in their code worth stealing:

- **macOS FIFO writes over 8 KiB can block forever.** They chunk every frame at
  4096 bytes (`pane_writers.rs`).
- **Open the FIFO non-blocking**, then clear `O_NONBLOCK`, so the daemon does
  not hang while tmux is still starting the reader.
- **Do not size the shared frame to the shortest mirror.** Their `watched_height`
  comment: folding to the minimum let "one stale 23-row window in a session
  nobody is looking at clip the list everywhere." Size to the mirror the user is
  actually watching.

## Why others abandoned the traveling pane

shelbi issue #1102, verbatim:

> The dashboard sidebar currently travels between tmux windows — on every window
> switch it is `join-pane`d out of the dashboard and into whichever window just
> became active. This has proven buggy (width reflow, focus-steal,
> orphaned/stranded panes, rescue-before-kill hacks).

They also needed cross-window width mirroring and a special case to skip
relocating into certain windows. Their fix was to stop moving it at all.

**Confirmed against this prototype:** `kill-window` on the window currently
hosting the pin destroys the pin. That is shelbi's "rescue-before-kill", and we
have it.

## The click trap (laatmux #42)

> tmux's default `MouseDown1Pane` is `select-pane -t = ; send-keys -M`, so the
> clicked sidebar pane **becomes the active pane before the view sees the
> click**.

So "one click reaches the sidebar" is true, but the other half is that keyboard
focus is then left *in* the sidebar — click a row to navigate and your typing
goes to the sidebar, not the agent. Worth weighing against the click cost that
motivated moving into tmux in the first place.

## Techniques to adopt (both verified here)

**Fixed hook index instead of a sentinel.** tmux-tree-sidebar writes
`set-hook -ga "after-select-window[$IDX]"` with a configurable index. Verified:
writing the same index three times leaves exactly one entry, with the user's
hook at `[0]` untouched. Idempotent by construction, survives config reload, and
needs no `@pin_hooks_loaded` flag — strictly better than the `%if` sentinel.

**`run-shell -b`.** Verified: a hook running `sleep 3` made `select-window` take
0s with `-b`, versus stalling the server without it. Every hook here should be
backgrounded.

**`kill-pane` does NOT fire `pane-exited`.** Verified: a program exiting on its
own fires `pane-exited` only; `kill-pane` fires `after-kill-pane` only. Pruning
a window left holding only its pin needs both hooks. tmux-tree-sidebar's
`prune.sh` is the model.

**Spawn-then-dock.** tmux-sidebar creates its pane with
`new-window -P -F '#{pane_id}'` and then `join-pane`s it into place, rather than
`split-window` directly.

## Upstream: tmux already wants this

The instinct that a static pane is a feature tmux is missing is correct, and
the maintainer agrees.

[tmux/tmux#719](https://github.com/tmux/tmux/issues/719) asks for `link-pane`,
the pane-level analogue of `link-window`. nicm's reply: *"Yes... I know... this
has been in the TODO file since forever."*

[tmux/tmux#5535](https://github.com/tmux/tmux/issues/5535) (opened 2026-08-25,
closed COMPLETED 2026-09-20) is a real design discussion for it: split today's
pane into a **view** (id, window/layout geometry, copy mode) and a shared
**`pane_pty`** (child process, PTY fd, parser, screen, history). nicm engaged on
sizing semantics (reuse `window-size`: `largest` / `smallest` / `latest`) and on
whether there should be a primary pane.

**But no code has landed.** Checked master on 2026-09-29: no `pane_pty`, no
`panelink`, no `link-pane` command. The design concluded; the implementation has
not started.

That reframes everything above: **agenmux's mirror mode is a userspace
reimplementation of `link-pane`** — one source of truth, many views, frames
pushed to each view over a FIFO. Every project in this table is hand-rolling a
primitive tmux has wanted for years and does not have. The traveling pane is the
cheap approximation; mirror mode is the expensive faithful one.

## Building the layout host outside tmux

The other direction is to own the layout: a program that draws a static frame
and runs terminals in it. Two facts worth having before starting.

**libghostty is not ready for this yet.** libghostty-vt ships today for Zig and
C, zero dependencies, and it is genuinely good — but it is *only* VT sequence
parsing and terminal state (cursor, styles, reflow, scrollback). Input handling,
GPU rendering and windowing are stated as future `libghostty-<x>` libraries.
[ghostling](https://github.com/ghostty-org/ghostling), the official minimum
viable terminal on the libghostty C API, is **1618 lines of C** and pulls in
Raylib for windowing and rendering, with a 2D renderer rather than GPU. That is
one terminal, with no splits, no layout, and no configuration.

**A two-pane static layout host is a Ghostty split.** Ghostty already does this,
and `focus-follows-mouse = true` plus `unfocused-split-opacity = 1` makes it
behave. What Ghostty's splits genuinely lack is programmability: `new_split`,
`goto_split`, `resize_split` and `equalize_splits` are keybind actions, and
`window-save-state` is macOS state restoration — there is no declarative layout
file and no IPC to compose one. If a layout host gets built, *that* is the gap
it should fill, not terminal emulation.

**A better-scoped use of libghostty-vt inside tmm:** agent detection currently
infers status by scraping `capture-pane` output near the live bottom of the
screen. libghostty-vt is exactly a library for maintaining correct terminal
state from a byte stream — pointing it at `pipe-pane` output would replace
screen-scraping with a real terminal model. Same dependency, real payoff, and no
terminal emulator to write.

## Where that leaves this prototype

The traveling pane is the approach two independent projects tried and dropped.
Mirror mode is where both converged. Before going further with `join-pane`, the
question worth answering is whether a payload needs to be one live process that
moves, or whether it can be a daemon rendering into dumb per-window readers —
because the second one makes the display-identity problem much smaller too: a
reader belongs to a window, and the daemon can render per-display content
without any pane ever moving.
