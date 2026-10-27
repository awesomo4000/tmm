// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The name at the top of the sidebar, in block letters. Several are kept
//! while one is being chosen; `TMM_BANNER=<name>` picks one, and `plain` is
//! the one-line title the others fall back to when the window is too narrow.

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
    .{ .name = "plain", .lines = &.{"tmm : tmux micro manager"} },
};

pub const plain = all[all.len - 1];
pub const default = all[0];

pub fn named(name: ?[]const u8) Banner {
    const wanted = name orelse return default;
    for (all) |banner| if (std.mem.eql(u8, banner.name, wanted)) return banner;
    return default;
}

test "every banner fits the four rows the header allows" {
    for (all) |banner| try std.testing.expect(banner.lines.len >= 1 and banner.lines.len <= 4);
    try std.testing.expectEqualStrings("quadrant", named(null).name);
    try std.testing.expectEqualStrings("heavy", named("heavy").name);
    try std.testing.expectEqualStrings("quadrant", named("nonsense").name);
}
