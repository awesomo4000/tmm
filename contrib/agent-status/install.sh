#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copy the status scripts where an agent can run them, and print the hooks to
# merge into its config.
#
#     install.sh            Claude Code: ~/.claude/hooks/tmm, settings.json
#     install.sh codex      Codex: ~/.codex/hooks/tmm, hooks.json
#
# Deliberately does not edit the agent's config. A config file has other hooks
# in it -- and other tools write to it -- so a merge done blind is a good way
# to lose someone else's hook. Printing the block and letting a person paste it
# costs one step and cannot destroy anything.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
agent=${1:-claude}
case "$agent" in
    claude)
        home_dir=$HOME/.claude
        config=$home_dir/settings.json
        snippet=$here/settings-snippet.json
        ;;
    codex)
        home_dir=$HOME/.codex
        config=$home_dir/hooks.json
        snippet=$here/codex-hooks-snippet.json
        ;;
    *)
        echo "usage: $0 [claude|codex]" >&2
        exit 2
        ;;
esac
default_dest=$home_dir/hooks/tmm
dest=${TMM_HOOK_DIR:-$default_dest}

mkdir -p "$dest"
for f in tmm-report.sh agent-status-hook.py; do
    [ -f "$here/$f" ] || { echo "missing $here/$f" >&2; exit 1; }
    cp "$here/$f" "$dest/$f"
    chmod +x "$dest/$f"
done

echo "installed to $dest:"
echo "  tmm-report.sh"
echo "  agent-status-hook.py"
echo

if [ "$dest" != "$default_dest" ]; then
    echo "note: the hooks below name $default_dest, so fix the"
    echo "      paths in them to match $dest"
    echo
fi

echo "merge this into $config under \"hooks\"."
echo "if an event already has hooks, add to its array rather than replacing it:"
echo
# The snippets say ~ for the home directory. Codex is given the path in full,
# as its own hooks are, rather than trusting it to expand ~.
if [ "$agent" = codex ]; then
    sed "s|~/|$HOME/|g" "$snippet"
    echo
    echo "Codex holds a new hook back until it has been reviewed: start codex,"
    echo "open /hooks, and trust these."
else
    cat "$snippet"
fi
echo
echo "check it with: tmm-report.sh state=working app=test   (from inside tmm)"
