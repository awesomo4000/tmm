#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Put a terminal back the way a full-screen program found it.
#
# Run it bare to fix a terminal that is already a mess:
#
#     tmm-restore.sh
#
# Or wrap a program so the terminal is restored however that program ends,
# which is the only way to cover a kill that cannot be caught:
#
#     tmm-restore.sh tmm
#
# The modes below are set by the program, not by the shell, and they live in
# the terminal emulator rather than in any process. So when a program dies
# without unsetting them the emulator keeps them, and the shell you get back
# is fine while the terminal is not: the mouse reports motion as escape
# sequences, keys arrive in a protocol nothing is decoding, and the screen may
# still be the alternate one.
#
# `reset` is the usual reflex and it is not enough. It sends what terminfo
# knows, and terminfo has no entry for mouse tracking or for the kitty
# keyboard stack, which are exactly the two that make a terminal unusable.

set -u

restore() {
    # Mouse tracking, in all three flavours a program may have enabled. 1003
    # is the one that reports plain motion, so it is the one that fills the
    # screen with escape sequences when you move the pointer over it.
    printf '\033[?1003l\033[?1002l\033[?1000l'
    # The coordinate encodings that go with them.
    printf '\033[?1006l\033[?1015l\033[?1005l'
    # Focus in and out reporting, which otherwise emits on every window switch.
    printf '\033[?1004l'
    # Bracketed paste, which otherwise wraps every paste in markers that the
    # shell shows as text.
    printf '\033[?2004l'
    # The kitty keyboard protocol. tmm pushes flags onto this stack, and a
    # leftover push is why a keystroke can arrive as an unprintable `CSI u`
    # sequence rather than a character. Popping is the documented undo.
    printf '\033[<u'
    # Synchronised output, in case a frame was left open: a terminal holding
    # one of these shows nothing at all until it is closed.
    printf '\033[?2026l'
    # Leave the alternate screen last, so everything above applies to the
    # screen the program was using and the original one comes back clean.
    printf '\033[?1049l'
    # Show the cursor, which a full-screen program hides.
    printf '\033[?25h'
    # And the line discipline, which is the one part that lives in the tty
    # rather than the emulator: echo and canonical mode off is what makes a
    # shell look dead even after the modes above are cleared.
    stty sane 2>/dev/null || true
}

if [ "$#" -eq 0 ]; then
    restore
    exit 0
fi

# With a command: run it, then restore whatever happened to it. This works
# for a signal that cannot be caught, which is the whole reason to do it out
# here rather than inside the program: SIGKILL ends the child and leaves this
# shell running, so the cleanup still happens. A program can handle its own
# SIGTERM and SIGINT, and cannot handle SIGKILL at all.
"$@"
status=$?
restore
exit $status
