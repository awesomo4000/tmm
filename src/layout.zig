// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Parser for tmux's classic (version 1) layout string, the form a control-mode
//! client receives in %layout-change unless it opts into new-layouts. Grammar
//! (tmux layout-custom.c):
//!
//!   layout := checksum "," cell
//!   cell   := WxH "," X "," Y [ "," pane-id ] [ "{" cell ("," cell)* "}"
//!                                             | "[" cell ("," cell)* "]" ]
//!
//!   "{" lays children left-to-right, "[" lays them top-to-bottom. A leaf cell
//!   carries a pane id; a split cell carries a bracket. The pane id is
//!   disambiguated from a following sibling exactly as tmux does: digits after
//!   the comma are a pane id unless an 'x' follows them (then they are the next
//!   cell's width and the comma is rewound).
//!
//! We flatten to leaf rectangles, which is what a compositor needs to place each
//! pane; split structure is discarded (borders can be derived from the gaps).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PaneRect = struct {
    /// tmux pane id as a number (the %N sigil is not in the layout string).
    /// Null for the rare leaf tmux emits without one.
    id: ?u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Error = error{MalformedLayout} || Allocator.Error;

/// Parse a layout string into its leaf pane rectangles, in document order.
pub fn parse(alloc: Allocator, layout: []const u8) Error![]PaneRect {
    var leaves: std.ArrayList(PaneRect) = .empty;
    errdefer leaves.deinit(alloc);
    var c: Cursor = .{ .s = stripChecksum(layout) };
    try parseCell(&c, &leaves, alloc, 0);
    if (c.i != c.s.len) return error.MalformedLayout;
    return leaves.toOwnedSlice(alloc);
}

const MAX_DEPTH = 32;

const Cursor = struct {
    s: []const u8,
    i: usize = 0,
    fn peek(self: Cursor) u8 {
        return if (self.i < self.s.len) self.s[self.i] else 0;
    }
};

fn parseCell(c: *Cursor, leaves: *std.ArrayList(PaneRect), alloc: Allocator, depth: u32) Error!void {
    if (depth > MAX_DEPTH) return error.MalformedLayout;

    const w = try readUint(c);
    try expect(c, 'x');
    const h = try readUint(c);
    try expect(c, ',');
    const x = try readUint(c);
    try expect(c, ',');
    const y = try readUint(c);

    // Optional pane id: a comma and digits, unless an 'x' follows (sibling).
    var id: ?u32 = null;
    if (c.peek() == ',') {
        const saved = c.i;
        c.i += 1;
        const start = c.i;
        while (isDigit(c.peek())) c.i += 1;
        if (c.peek() == 'x' or c.i == start) {
            c.i = saved;
        } else {
            id = std.fmt.parseInt(u32, c.s[start..c.i], 10) catch return error.MalformedLayout;
        }
    }

    const open = c.peek();
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        else => {
            // Leaf: nothing more to consume for this cell.
            try leaves.append(alloc, .{ .id = id, .x = x, .y = y, .w = w, .h = h });
            return;
        },
    };

    // Split: children separated by commas, closed by the matching bracket.
    while (true) {
        c.i += 1; // skip the opening bracket or a separating comma
        try parseCell(c, leaves, alloc, depth + 1);
        if (c.peek() != ',') break;
    }
    try expect(c, close);
}

fn stripChecksum(s: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return s;
    const head = s[0..comma];
    if (head.len == 0 or head.len > 4) return s;
    for (head) |ch| if (!isHex(ch)) return s;
    return s[comma + 1 ..];
}

fn readUint(c: *Cursor) Error!u32 {
    const start = c.i;
    while (isDigit(c.peek())) c.i += 1;
    if (c.i == start) return error.MalformedLayout;
    return std.fmt.parseInt(u32, c.s[start..c.i], 10) catch error.MalformedLayout;
}

fn expect(c: *Cursor, ch: u8) Error!void {
    if (c.peek() != ch) return error.MalformedLayout;
    c.i += 1;
}

inline fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}
inline fn isHex(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

test "single pane layout" {
    const a = std.testing.allocator;
    const r = try parse(a, "bb62,80x24,0,0,1");
    defer a.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(PaneRect{ .id = 1, .x = 0, .y = 0, .w = 80, .h = 24 }, r[0]);
}

test "left-right split yields two side-by-side leaves" {
    const a = std.testing.allocator;
    const r = try parse(a, "abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer a.free(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(PaneRect{ .id = 1, .x = 0, .y = 0, .w = 40, .h = 24 }, r[0]);
    try std.testing.expectEqual(PaneRect{ .id = 2, .x = 41, .y = 0, .w = 39, .h = 24 }, r[1]);
}

test "top-bottom split yields stacked leaves" {
    const a = std.testing.allocator;
    const r = try parse(a, "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]");
    defer a.free(r);
    try std.testing.expectEqual(PaneRect{ .id = 1, .x = 0, .y = 0, .w = 80, .h = 12 }, r[0]);
    try std.testing.expectEqual(PaneRect{ .id = 2, .x = 0, .y = 13, .w = 80, .h = 11 }, r[1]);
}

test "nested split keeps every leaf with correct geometry" {
    const a = std.testing.allocator;
    const r = try parse(a, "1234,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}");
    defer a.free(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqual(@as(?u32, 1), r[0].id);
    try std.testing.expectEqual(PaneRect{ .id = 2, .x = 41, .y = 0, .w = 39, .h = 12 }, r[1]);
    try std.testing.expectEqual(PaneRect{ .id = 3, .x = 41, .y = 13, .w = 39, .h = 11 }, r[2]);
}

test "raw cell without checksum parses" {
    const a = std.testing.allocator;
    const r = try parse(a, "80x24,0,0,7");
    defer a.free(r);
    try std.testing.expectEqual(@as(?u32, 7), r[0].id);
}

test "malformed layouts are rejected" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "bb62,80x24,0,0{40x24,0,0,1", "bb62,80x24,0", "bb62,", "bb62,xyz", "bb62,80x24,0,0,1}" }) |bad| {
        try std.testing.expectError(error.MalformedLayout, parse(a, bad));
    }
}

test "high pane ids and large geometry" {
    const a = std.testing.allocator;
    const r = try parse(a, "ffff,200x50,0,0{100x50,0,0,1234,99x50,101,0,5678}");
    defer a.free(r);
    try std.testing.expectEqual(@as(?u32, 1234), r[0].id);
    try std.testing.expectEqual(@as(?u32, 5678), r[1].id);
    try std.testing.expectEqual(@as(u32, 101), r[1].x);
}
