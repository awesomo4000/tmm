// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The name at the top of the sidebar, in block letters. Each launch draws a
//! different one at random; `TMM_BANNER=<name>` asks for one by name, and
//! `plain` is the one-line title the others fall back to when the window is
//! too narrow, never drawn at random.

const std = @import("std");

pub const Banner = struct { name: []const u8, lines: []const []const u8 };

pub const all = [_]Banner{
    .{ .name = "quadrant", .lines = &.{ "▗       ", "▜▘▛▛▌▛▛▌", "▐▖▌▌▌▌▌▌" } },
    .{ .name = "slant", .lines = &.{ "▐          ", "▜▀ ▛▚▀▖▛▚▀▖", "▐ ▖▌▐ ▌▌▐ ▌", " ▀ ▘▝ ▘▘▝ ▘" } },
    .{ .name = "chunky", .lines = &.{ "▄█▄  ▄▄▄▄  ▄▄▄▄ ", " █   █ █ █ █ █ █", "  ▀▀ ▀ ▀ ▀ ▀ ▀ ▀" } },
    .{ .name = "block", .lines = &.{ " ██                    ", "▀██▀▀ ███▄███▄ ███▄███▄", " ██   ██ ██ ██ ██ ██ ██", " ██   ██ ██ ██ ██ ██ ██" } },
    .{ .name = "heavy", .lines = &.{ "╺┳╸┏┳┓┏┳┓", " ┃ ┃┃┃┃┃┃", " ╹ ╹ ╹╹ ╹" } },
    .{ .name = "round", .lines = &.{ "╶┬╴╭┬╮╭┬╮", " │ ││││││", " ╵ ╵ ╵╵ ╵" } },
    .{ .name = "light", .lines = &.{ "╶┬╴┌┬┐┌┬┐", " │ ││││││", " ╵ ╵ ╵╵ ╵" } },
    .{ .name = "double", .lines = &.{ "═╔╝╔╔ ╔╔ ", " ║ ║║║║║║", " ╝ ╝╝╝╝╝╝" } },
    .{ .name = "pipes", .lines = &.{ "╋┏┳┓┏┳┓", "┗┛┗┗┛┗┗" } },
    .{ .name = "ascii", .lines = &.{ "_|___ __ ", " |_||||||" } },
    .{ .name = "plain", .lines = &.{"tmm : tmux µmanager"} },
};

pub const plain = all[all.len - 1];
/// Every banner but `plain`, which is only a fallback.
const lettered = all[0 .. all.len - 1];

/// The banner `name` asks for, or one of the lettered ones picked by `roll`
/// when it names none.
pub fn choose(name: ?[]const u8, roll: u64) Banner {
    if (name) |wanted| for (all) |banner| if (std.mem.eql(u8, banner.name, wanted)) return banner;
    return lettered[roll % lettered.len];
}

test "every banner fits the four rows the header allows" {
    for (all) |banner| try std.testing.expect(banner.lines.len >= 1 and banner.lines.len <= 4);
    try std.testing.expectEqualStrings("heavy", choose("heavy", 0).name);
    try std.testing.expectEqualStrings("plain", choose("plain", 0).name);
    try std.testing.expectEqualStrings("quadrant", choose("nonsense", 0).name);
}

test "a random banner is never the plain fallback" {
    var roll: u64 = 0;
    while (roll < all.len * 3) : (roll += 1) try std.testing.expect(choose(null, roll).lines.len > 1);
}
