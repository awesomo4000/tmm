# tmux-pin

Keep a pane pinned to a display: present no matter which window that display
is looking at.

Status: working prototype, verified against tmux 3.7c on macOS. Generic — it
knows nothing about any particular payload; the pinned program is just
`PIN_CMD`.

## The problem

A tmux pane belongs to exactly one window, and a window is what a client
displays. There is no pinned or global pane, so "always visible" would
normally mean running one copy per window.

The status line is the only genuinely always-visible surface (up to 5 rows;
`set -g status 6` errors), but it is text only, horizontal, and not
interactive. `link-window` shares a whole window across sessions, not a pane
beside your work. `display-popup` is modal to the client.

So instead of copies, tmux-pin moves one pane around with `join-pane`, which
preserves the pty and the running process.

## How it works

Each display (tmux client) owns one pinned pane, tagged with a pane option
`@pin_display=<that display's tty>`. Hooks pass the triggering client's tty to
`tmux-pin.sh`, which finds that display's pane and reparents it into the window
that display is now viewing. Other displays are untouched.

Verified: two displays, two pins, each following only its owner, pane pids
constant across every move, always at `x=0` with width 30. Detaching a display
reaps its pin and leaves the other alone. Stable across repeated runs.

## Try it

```sh
./demo.sh           # headless: prints where each pin lands
./demo.sh --watch   # sets up, tells you how to attach two terminals
```

Runs on a throwaway socket (`tmuxpindemo`); never touches your `default`
server. Tear down with `tmux -L tmuxpindemo kill-server`.

## Install

`tmux-pin-install.sh` inspects a live server and reports tmux version, `mouse`,
`prefix`, `default-terminal`, every existing entry on the hooks it wants, and
any pins already placed.

```sh
./tmux-pin-install.sh --check      # report state, change nothing
./tmux-pin-install.sh --print      # emit a config fragment, change nothing
./tmux-pin-install.sh --install    # append hooks to the RUNNING server
./tmux-pin-install.sh --uninstall  # remove only tmux-pin's entries
```

Three ways to apply it, in increasing permanence:

1. **Runtime only, zero file edits** — `--install` applies `set-hook -ga` to
   the running server. Dies with the server.
2. **An include file** — `--print` emits a fragment; add one line to
   `~/.tmux.conf`: `source-file -q ~/.config/tmux-pin/pin.tmux.conf`. The `-q`
   means a missing file is silently ignored, so the config never breaks if
   tmux-pin goes away.
3. **Print and paste** — same output, no writes at all.

Environment: `PIN_CMD` (what to spawn for a display with no pin yet),
`PIN_SIZE` (columns, default 30), `PIN_SOCKET` (for testing).

## tmux gotchas found building this

All of these fail silently.

1. **`#{session_id}` is literally `$0`.** Passed through `run-shell`, the
   hook's `sh` eats it as a positional parameter and it arrives as `sh`. Use
   `#{q:session_id}`.
2. **An empty tmux format expands to nothing**, deleting the argument and
   shifting every argument after it. Use `--flag=value` so an empty value still
   produces a token: `--tty=#{q:client_tty}`.
3. **`client_tty` and `hook_client` are mutually exclusive.** Client-driven
   switches (`switch-client -c`, i.e. real use) populate `client_tty` and leave
   `hook_client` empty. An externally driven `select-window` does the reverse —
   and reports an *arbitrary* client. A `hook_client` fallback is therefore
   actively harmful: one dragged a display's pin into a session that display
   was not viewing. There is deliberately no such fallback.
4. **`display-message -c <tty>` is not reliable at attach time.** During a
   client-attached race it reported another client's window entirely —
   measured: `-c` on a client attached to `beta` returned `alpha:1`, and the
   hooks fired twice for one tty and never for the other. Resolution goes
   through the authoritative client table instead: map tty to session with
   `list-clients`, then ask that session for its current window.
5. **`display-message -p` with no explicit `-t`** resolves to something
   unhelpful (it returned the pin's own window). Every target must be explicit.
6. **`set-hook -ga` appends every time**, so re-sourcing an unguarded include
   stacks duplicates — measured 4 -> 8 -> 12 entries across three reloads. The
   emitted fragment is wrapped in a `%if` sentinel; verified stable at 4 across
   four sources with a pre-existing user hook left intact.

`join-pane` also reshapes windows and can re-trigger the hook that called it,
hence the per-display `@pin_moving_*` guard.

## Alternative: nested tmux

Rather than moving a pane, make the sidebar structural. An **outer** tmux holds
one window with two panes — the payload on the left, and on the right a client
attached to an **inner** tmux that holds the real workspace. Switching windows
happens one level down, so the sidebar cannot move. No hooks, no `join-pane`,
none of the failure modes in PRIOR-ART.md.

```sh
tmux -L inner new-session -d -s work
tmux -L outer new-session -d -s frame
tmux -L outer split-window -h -l 170 -t frame:1 \
  "bash -c 'while :; do tmux -L inner attach -t work || sleep 1; done'"
tmux -L outer set -g prefix None    # outer takes no keys; everything passes through
tmux -L outer set -g status off     # no doubled status bar
```

Verified:

- Outer layout is byte-identical across inner window switches.
- The inner client's tty **is** the outer pane's pty, and resizing the outer
  split resizes the inner client automatically (170x50 -> 120x50).
- With `prefix None`, `C-a c` sent through the outer reached the inner tmux and
  created a window there. Root-table mouse bindings still work, so clicking
  between sidebar and workspace behaves normally.
- The respawn loop matters: detaching the inner (easy to do by muscle memory
  with `prefix d`) otherwise collapses the work pane and the sidebar expands to
  fill the window. With the loop, the layout is unchanged and the client
  reattaches.

Costs:

- **Two tmux servers.** Every byte in the work area is rendered twice — inner
  into the pane, outer into the terminal. Not measured here.
- **Separate sockets are mandatory.** Attaching to the same server from inside
  itself is refused: `sessions should be nested with care, unset $TMUX to force`.
- **Untested:** nested copy-mode, scrollback, and OSC 52 clipboard passthrough,
  all of which are known friction points for nested tmux.

The usual objection to nesting is prefix collision, but that assumes you drive
both levels. Here the outer is an inert frame — one window, two panes, never
changing — so `prefix None` costs nothing and the collision disappears.

## Known limits

**Two displays on one session.** They share a current window, so both pins land
in it — reproduced, and it squeezed the work pane to 18 columns. tmux's answer
is grouped sessions (`new-session -t <existing>`): the same window objects with
an independent current window per session. Verified one session on `@0` while
its group peer sat on `@2`.

**`kill-window` destroys the pin.** If the window currently hosting a pin is
killed, the pin goes with it — verified. Other projects called this
"rescue-before-kill" and needed a dedicated escape path.

**A click leaves keyboard focus in the pin.** tmux's `MouseDown1Pane` is
`select-pane -t = ; send-keys -M`, so the pane is activated before the payload
sees the click. One click does reach the payload, but typing afterwards goes to
the pin rather than your work.

**One pin per display.** The lookup takes the first match and stops. Multiple
pins would need position and size as per-pin pane options rather than the
hardcoded `-b -h -l`, plus a placement order.

See [PRIOR-ART.md](PRIOR-ART.md): seven existing projects were read, two of
them tried this same traveling-pane approach and abandoned it, and the
alternative both converged on (a daemon rendering into per-window reader panes)
is documented there along with techniques worth adopting.

## Open design question: what is a display?

This is the real problem, and it is not the pane moving.

tmux offers no durable client identity. `client_name` *is* `client_tty`, and a
tty belongs to the terminal process — close the window and reopen it and the
identity is gone, and the reaper kills the orphaned pin. Per-client environment
looked like a way to carry a stable label, but `#{client_environment:VAR}`
returned empty in 3.7c even for a control variable that was definitely set, so
treat that route as closed until shown otherwise.

So a general utility needs a **pluggable identity resolver** rather than
assuming tty. Notably tmm already has a better one than tmux does: it traces
parent processes to the terminal app and disambiguates same-named ones by tty.
Settling this is the prerequisite for extracting tmux-pin into its own repo.
