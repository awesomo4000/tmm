// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The colour field compost draws its window borders from, so tmm's accents
//! continue the frame it usually sits in rather than clashing with it.
//!
//! Four corners blended bilinearly over the window: pink to violet along the
//! top, purple to teal along the bottom. The corners and the dim and lift
//! amounts are compost's (src/frame.zig there); change them in both places.

const std = @import("std");

pub const RGB = [3]u8;

const top_left: RGB = .{ 244, 55, 151 };
const top_right: RGB = .{ 111, 85, 240 };
const bottom_left: RGB = .{ 174, 65, 209 };
const bottom_right: RGB = .{ 49, 179, 144 };
/// What an inactive colour fades toward, and what a background tint starts
/// from: near the dark terminal background the field is drawn over.
const shade: RGB = .{ 30, 30, 34 };
const white: RGB = .{ 255, 255, 255 };

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
/// row is drawn in. Not compost's; it borrows the bottom-right corner.
const cool_top: RGB = .{ 92, 150, 245 };
pub fn cool(height: u16, y: u16) RGB {
    return mix(cool_top, bottom_right, y, @max(height, 1) - 1);
}

/// Compost's unfocused border: the same hue, mostly faded out.
pub fn dim(c: RGB) RGB {
    return mix(shade, c, 60, 100);
}

/// Compost's hovered border: the same hue, lifted toward white.
pub fn lift(c: RGB) RGB {
    return mix(c, white, 30, 100);
}

/// A background carrying `percent` of the field over the dark shade.
pub fn wash(c: RGB, percent: u32) RGB {
    return mix(shade, c, percent, 100);
}

test "the corners are compost's and the middle is between them" {
    try std.testing.expectEqual(top_left, at(10, 5, 0, 0));
    try std.testing.expectEqual(top_right, at(10, 5, 9, 0));
    try std.testing.expectEqual(bottom_left, at(10, 5, 0, 4));
    try std.testing.expectEqual(bottom_right, at(10, 5, 9, 4));
    // A one-cell window has no span to blend over and must not divide by it.
    try std.testing.expectEqual(top_left, at(1, 1, 0, 0));
    try std.testing.expectEqual(shade, wash(top_left, 0));
}
