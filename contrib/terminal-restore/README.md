# terminal-restore/

Put a terminal back after a full-screen program died without cleaning up.

The symptom is unmistakable: the shell comes back and works, but moving the
mouse over the window spits escape sequences, or keys arrive as garbage, or
the screen is still the alternate one. tmm turns on mouse tracking and the
kitty keyboard protocol when it starts, and turns them off on the way out. If
it never gets to the way out, the terminal keeps them.

    tmm-restore.sh                 # fix a terminal that is already a mess
    tmm-restore.sh tmm             # or wrap, so it cannot happen again

## Why `reset` does not do it

`reset` sends what terminfo knows about, and terminfo has no entry for mouse
tracking or for the kitty keyboard stack. Those are DEC private modes a
program sets directly, so they survive the thing everyone reaches for first.
That is why this feels like it should have a keypress and does not.

## Wrapping it for good

A program can handle its own `SIGTERM` and `SIGINT`. It cannot handle
`SIGKILL`, and it cannot do anything at all if it is stopped dead — so no
amount of care inside tmm covers every case. The cleanup has to live in a
process that outlives it, which is what wrapping gives you: the kill lands on
tmm, the wrapper keeps running.

In `~/.bashrc` or `~/.zshrc`:

```bash
tmm() {
  command tmm "$@"
  local status=$?
  printf '\033[?1003l\033[?1002l\033[?1000l\033[?1006l\033[?1015l\033[?1005l'
  printf '\033[?1004l\033[?2004l\033[<u\033[?2026l\033[?1049l\033[?25h'
  return $status
}
```

It costs nothing when tmm exited cleanly: unsetting a mode that is already
unset is a no-op.

## Or fix it for every program at once

The same problem belongs to vim, to anything curses, to any program that ever
gets killed mid-draw. A prompt hook heals all of them at the next prompt
rather than per program:

```bash
# bash
PROMPT_COMMAND='printf "\033[?1003l\033[?1002l\033[?1000l\033[?2004l\033[<u"'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# zsh
precmd() { printf '\033[?1003l\033[?1002l\033[?1000l\033[?2004l\033[<u' }
```

Deliberately a shorter list than the script: `1049l` would fight a program
that legitimately wants the alternate screen, and `stty sane` on every prompt
would undo deliberate `stty` settings. This is the version that is safe to run
unconditionally, before every prompt, forever.

The trade is that it also turns off a mode something at the prompt wanted —
a shell with a mouse-aware line editor, say. Rare, and worth knowing about
before pasting it.

## How other programs handle this

- **Most don't.** vim leaves a terminal dirty when it is killed, which is why
  typing `reset` is muscle memory for anyone who has used a terminal for long.
- **tmux and screen sidestep it.** State lives in a server that does not die
  with the client, and a client re-initialises the terminal on attach, so the
  mess heals itself on reattach. That is an architectural answer, not a
  cleanup one, and it is why a tmm running inside a tmux pane is easy to
  recover and a tmm in a bare window is not.
- **Shells half-fix it.** bash and zsh reset the line discipline before each
  prompt, which is why `stty sane` is often unnecessary. Neither touches DEC
  private modes, which is precisely the gap here.
- **Terminal emulators offer a Reset.** Ghostty, iTerm2 and Terminal.app all
  have one in the menus, and unlike `reset` the command it does clear these
  modes, because the emulator is resetting its own parser rather than sending
  sequences to itself.

So: a supervising process can restore a terminal in every case, and that is
the only thing that can. The program itself cannot, because the case that
matters is the one where the program is already gone.
