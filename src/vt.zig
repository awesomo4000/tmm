// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! libghostty-vt wrapper: one `Terminal` per tmux pane for the control-mode
//! compositor. Pane bytes arrive as decoded `%output` (see control.zig) and are
//! fed here; the compositor reads the resulting grid back out.
//!
//! Kitty graphics notes (verified against ghostty 83edd49):
//!   - The `kitty_graphics` build option defaults to true and is only forced
//!     off on freestanding targets, so no build wiring is needed here.
//!   - Image storage is still off at runtime until `kitty_image_storage_limit`
//!     is non-zero, which is why `Options.kitty_image_storage_limit` is set.
//!   - Decoding PNG payloads additionally requires a decoder installed through
//!     ghostty's `sys` hook; libghostty-vt ships none. `zigimg` is already in
//!     the dependency graph (via vaxis) and can serve. Not wired yet — only
//!     needed once the Phase 4 image bridge lands.

const std = @import("std");
const ghostty = @import("ghostty-vt");

/// Per-pane terminal state.
pub const Terminal = ghostty.Terminal;

/// Default image storage per pane. Non-zero so kitty placements are retained.
pub const default_kitty_storage_limit: usize = 16 * 1024 * 1024;

/// Create a terminal sized to a pane rect from layout.zig.
pub fn initPane(
    io: std.Io,
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
) !Terminal {
    return try Terminal.init(io, alloc, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .kitty_image_storage_limit = default_kitty_storage_limit,
    });
}

test "libghostty-vt is wired in and exposes kitty graphics" {
    // Compiles only if the kitty_graphics build option is on: the namespace is
    // an empty struct otherwise, so ImageStorage would not resolve.
    try std.testing.expect(@hasDecl(ghostty.kitty.graphics, "ImageStorage"));
}
