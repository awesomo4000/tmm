#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The focus key, as the tests have to type it and as tmm shows it.

The key that moves tmm focus between the sidebar and the region is a runtime
choice (src/focuskey.zig, `--focus-key`, `TMM_FOCUS_KEY`). It was a literal
in half a dozen harnesses while it was fixed, which is why it is here now: a
changed default should break one constant and not a search for every test
that happened to spell it out.

These harnesses are ptys, not terminals, so they encode the key themselves.
`FOCUS` is the kitty form -- the one tmm gets from the terminals it targets,
since it asks for the protocol at startup. `FOCUS_LEGACY` is the same
physical key from a terminal that has no such protocol, which is one C0 byte
and so a different key as far as libvaxis can tell; tmm accepts both, and
tests/split_shell.py is where that is actually asserted.
"""

# The spelling tmm defaults to, and how to type it: CSI u, unshifted
# codepoint 0x60, modifier bitmask 5 (ctrl).
FOCUS_SPELLING = 'ctrl+`'
FOCUS = b'\x1b[96;5u'

# The same key from a terminal that answered no progressive-enhancement
# query: NUL, which libvaxis reports as ctrl+@.
FOCUS_LEGACY = b'\x00'

# How tmm spells it in the sidebar status line.
FOCUS_LABEL = 'ctrl+`'

# Which environment variable names the key, for the tests that set it and the
# tests that must make sure it is unset.
ENV_VAR = 'TMM_FOCUS_KEY'

# A second key, for the tests that rebind one: tests/focus_key.py asserts that
# the key tmm was not given stops moving focus, which needs two of them.
ALT_FOCUS_SPELLING = 'f12'
ALT_FOCUS = b'\x1b[24~'
ALT_FOCUS_LABEL = 'F12'
