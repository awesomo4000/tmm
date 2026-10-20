#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copy the status scripts where Claude Code can run them, and print the
# settings to merge.
#
# Deliberately does not edit settings.json. A settings file has other hooks in
# it -- and other tools write to it -- so a merge done blind is a good way to
# lose someone else's hook. Printing the block and letting a person paste it
# costs one step and cannot destroy anything.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=${TMM_HOOK_DIR:-$HOME/.claude/hooks/tmm}

mkdir -p "$dest"
for f in tmm-report.sh claude-status-hook.py; do
    [ -f "$here/$f" ] || { echo "missing $here/$f" >&2; exit 1; }
    cp "$here/$f" "$dest/$f"
    chmod +x "$dest/$f"
done

echo "installed to $dest:"
echo "  tmm-report.sh"
echo "  claude-status-hook.py"
echo

if [ "$dest" != "$HOME/.claude/hooks/tmm" ]; then
    echo "note: the snippet below spells out ~/.claude/hooks/tmm, so fix the"
    echo "      paths in it to match $dest"
    echo
fi

echo "merge this into ~/.claude/settings.json under \"hooks\"."
echo "if an event already has hooks, add to its array rather than replacing it:"
echo
cat "$here/settings-snippet.json"
echo
echo "check it with: tmm-report.sh state=working app=test   (from inside tmm)"
