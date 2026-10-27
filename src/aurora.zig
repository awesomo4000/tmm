// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The colour field tmm's accents are drawn from, so the title, headings and
//! names read as one sweep of colour rather than separate paints.
//!
//! Four corners blended bilinearly over the window: pink to violet along the
//! top, purple to teal along the bottom. `dim` fades a colour toward the dark
//! background and `lift` raises it toward white.

const std = @import("std");
const palette = @import("palette.zig");

pub const RGB = palette.RGB;

const top_left = palette.field_top_left;
const top_right = palette.field_top_right;
const bottom_left = palette.field_bottom_left;
const bottom_right = palette.field_bottom_right;
const shade = palette.field_shade;
const white = palette.field_lift;

pub fn mix(a: RGB, b: RGB, amount: u32, span: u32) RGB {
    const total = @max(1, span);
    const n = @min(amount, total);
    var result: RGB = undefined;
    for (&result, a, b) |*out, from, to| out.* = @intCast((@as(u32, from) * (total - n) + @as(u32, to) * n) / total);
    return result;
}

/// The field at a cell of a window `width` by `height`.
pub fn at(width: u16, height: u16, x: u16, y: u16) RGB {
    const across = @max(width, 1) - 1;
    const down = @max(height, 1) - 1;
    const upper = mix(top_left, top_right, x, across);
    const lower = mix(bottom_left, bottom_right, x, across);
    return mix(upper, lower, y, down);
}

/// The cool end of the field on its own, blue at the top to teal at the
/// bottom, for names that have to stand apart from the purple the rest of a
/// row is drawn in. It ends at the bottom-right corner.
pub fn cool(height: u16, y: u16) RGB {
    return mix(palette.session_name_top, bottom_right, y, @max(height, 1) - 1);
}

/// The same hue, mostly faded out, for what is not current.
pub fn dim(c: RGB) RGB {
    return mix(shade, c, 60, 100);
}

/// The same hue, lifted toward white, for what is current.
pub fn lift(c: RGB) RGB {
    return mix(c, white, 30, 100);
}

/// A background carrying `percent` of the field over the dark shade.
pub fn wash(c: RGB, percent: u32) RGB {
    return mix(shade, c, percent, 100);
}

test "the corners are the corners and the middle is between them" {
    try std.testing.expectEqual(top_left, at(10, 5, 0, 0));
    try std.testing.expectEqual(top_right, at(10, 5, 9, 0));
    try std.testing.expectEqual(bottom_left, at(10, 5, 0, 4));
    try std.testing.expectEqual(bottom_right, at(10, 5, 9, 4));
    // A one-cell window has no span to blend over and must not divide by it.
    try std.testing.expectEqual(top_left, at(1, 1, 0, 0));
    try std.testing.expectEqual(shade, wash(top_left, 0));
}
