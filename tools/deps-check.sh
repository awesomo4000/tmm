#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# How far behind is the vendored libghostty-vt?
#
# The tarball comes from ghostty's rolling `tip` release, so there is no
# version to compare against -- only the commit recorded in vendor/README.md
# against upstream main. Prints the changes that touch what tmm parses or
# emits, because those are the ones that decide whether an update matters.
# Needs `gh`.
set -e
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pinned=$(sed -n 's/.*ghostty commit.*`\([0-9a-f]\{40\}\)`.*/\1/p' "$root/vendor/README.md" | head -1)
if [ -z "$pinned" ]; then
    echo "could not read the pinned commit from vendor/README.md" >&2
    exit 2
fi
# Capabilities tmm is waiting on. A list here rather than a note somewhere,
# with a canary: the last entry is a hook tmm already uses, so every run shows
# the check finding something. If the canary reads absent, the check itself is
# broken and the other answers mean nothing -- a detector nobody has seen fire
# is not evidence.
# because the question is exact -- does the embedder hook exist yet -- and a
# note does not answer it. Each line is a description, the file it lives in,
# and the pattern that means it is there. Checked against the vendored copy
# and against upstream, so this says either "wire it up" or "still waiting".
watch_capabilities() {
    echo
    echo "capabilities tmm is waiting on:"
    # shellcheck disable=SC2039
    printf '%s\n' \
        "OSC 3008 hierarchical context, embedder hook|src/terminal/stream_terminal.zig|hierarchical_context:" \
        "canary: OSC 7501 hook, which tmm already uses|src/terminal/stream_terminal.zig|program_status:" \
    | while IFS='|' read -r what file pattern; do
        local_state="absent"
        if [ -d "$root/zig-pkg" ]; then
            if grep -rqs -- "$pattern" "$root"/zig-pkg/ghostty-*/"$file" 2>/dev/null; then
                local_state="PRESENT -- wire it up"
            fi
        fi
        upstream_state="absent"
        if gh api "repos/ghostty-org/ghostty/contents/$file" \
            --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
            | grep -qs -- "$pattern"; then
            upstream_state="PRESENT on main -- bump the pin"
        fi
        echo "  $what"
        echo "    vendored: $local_state"
        echo "    upstream: $upstream_state"
    done
}

echo "pinned libghostty-vt: $pinned"
if ! command -v gh >/dev/null 2>&1; then
    echo "gh not installed; cannot compare with upstream"
    exit 0
fi
behind=$(gh api "repos/ghostty-org/ghostty/compare/$pinned...main" --jq '.total_commits' 2>/dev/null || echo "")
if [ -z "$behind" ]; then
    echo "could not reach GitHub to compare"
    exit 0
fi
echo "upstream main is ahead by: $behind commit(s)"
if [ "$behind" = "0" ]; then
    echo "up to date"
    watch_capabilities
    exit 0
fi
echo
echo "changes that touch what tmm parses or emits:"
gh api "repos/ghostty-org/ghostty/compare/$pinned...main" --jq '.commits[] | .commit.message' 2>/dev/null \
    | grep -iE '^(vt|terminal|libghostty-vt|osc|input)[:/ ]|program.status|7501|kitty' \
    | sed 's/^/  /' | sort -u | head -24
watch_capabilities

echo
echo "to update, follow vendor/README.md: download the tip asset, re-record the"
echo "hash with zig fetch, then zig build test -- the OSC 7501 and kitty"
echo "capability tests in src/vt.zig must still pass."
