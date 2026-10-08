# contrib/

## tmux-pin/

A generic tmux utility: keep a pane pinned to a display, present no matter
which window that display is looking at. See [tmux-pin/README.md](tmux-pin/README.md).

It knows nothing about tmm — the pinned program is just `PIN_CMD`. tmm is
intended to be its first consumer, not its owner.

### Why it exists

Running tmm in its own terminal window costs a click: macOS click-to-focus
means the first click activates the window and the second does the thing.
macOS has no system-wide focus-follows-mouse, and Ghostty's
`focus-follows-mouse` explicitly does not apply to unfocused windows. Inside
tmux there is no extra click — the default binding is
`MouseDown1Pane  select-pane -t = \; send-keys -M`, which selects the pane and
forwards the same click to the application.

That argues for running tmm as a pane rather than a separate window. But a
pane belongs to exactly one window, which is the problem tmux-pin solves.

The alternative worth remembering: running tmm as a **Ghostty split** rather
than a tmux pane also costs no extra click (with `focus-follows-mouse = true`
and `unfocused-split-opacity = 1`), and because the split sits outside tmux it
never moves and never fights multiple clients. tmux-pin is the right answer
only if tmm should live *inside* tmux.

### Status

Working prototype, not wired into tmm. Nothing here is installed by default and
none of it touches `~/.tmux.conf` unless you ask it to.

Before extracting tmux-pin into its own repo, settle the open design question
at the end of its README: tmux has no durable display identity, and tmm's
parent-process tracing is a better answer than the tty this prototype uses.
