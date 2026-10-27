// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The order sessions are listed in, as the person arranged them by dragging
//! or with Shift-J and Shift-K. Held by session id, so a rename keeps its
//! place, and only for as long as this tmm runs.

const std = @import("std");
const m = @import("model.zig");

pub const Order = struct {
    /// Session ids, owned, first listed first.
    ids: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Order, a: std.mem.Allocator) void {
        for (self.ids.items) |id| a.free(id);
        self.ids.deinit(a);
    }

    pub fn clear(self: *Order, a: std.mem.Allocator) void {
        for (self.ids.items) |id| a.free(id);
        self.ids.clearRetainingCapacity();
    }

    /// Follow the server's sessions: forget the ones that are gone, and put
    /// new ones at the bottom, in the server's order, so creating a session
    /// never moves the others.
    pub fn sync(self: *Order, a: std.mem.Allocator, sessions: []const m.Session) !void {
        var i: usize = 0;
        while (i < self.ids.items.len) {
            const id = self.ids.items[i];
            const present = for (sessions) |session| {
                if (std.mem.eql(u8, session.id, id)) break true;
            } else false;
            if (present) i += 1 else a.free(self.ids.orderedRemove(i));
        }
        for (sessions) |session| if (self.indexOf(session.id) == null) {
            const id = try a.dupe(u8, session.id);
            errdefer a.free(id);
            try self.ids.append(a, id);
        };
    }

    pub fn indexOf(self: Order, id: []const u8) ?usize {
        for (self.ids.items, 0..) |held, i| if (std.mem.eql(u8, held, id)) return i;
        return null;
    }

    /// Put `id` where position `to` is, the others closing up behind it:
    /// dropped on a session below, it lands after it; on one above, before.
    pub fn moveTo(self: *Order, id: []const u8, to: usize) void {
        const from = self.indexOf(id) orelse return;
        if (self.ids.items.len == 0) return;
        const held = self.ids.orderedRemove(from);
        const at = @min(to, self.ids.items.len);
        // Capacity is already there: one item came out just above.
        self.ids.insertAssumeCapacity(at, held);
    }

    /// One place down for a positive `by`, one up for a negative, stopping
    /// at the ends.
    pub fn step(self: *Order, id: []const u8, by: i2) void {
        const from = self.indexOf(id) orelse return;
        if (by < 0 and from == 0) return;
        if (by > 0 and from + 1 >= self.ids.items.len) return;
        self.moveTo(id, if (by < 0) from - 1 else from + 1);
    }

    /// The index into `sessions` of each session, in listed order: the
    /// arranged ones first, then any the order has not seen yet.
    pub fn arrange(self: Order, a: std.mem.Allocator, sessions: []const m.Session) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(a);
        for (self.ids.items) |id| for (sessions, 0..) |session, i| {
            if (std.mem.eql(u8, session.id, id)) {
                try out.append(a, i);
                break;
            }
        };
        for (sessions, 0..) |session, i| if (self.indexOf(session.id) == null) try out.append(a, i);
        return out.toOwnedSlice(a);
    }
};

fn named(id: []const u8) m.Session {
    return .{ .id = id, .name = id, .path = "" };
}

fn expectOrder(order: Order, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, order.ids.items.len);
    for (want, order.ids.items) |w, got| try std.testing.expectEqualStrings(w, got);
}

test "new sessions go to the bottom and gone ones are forgotten" {
    const a = std.testing.allocator;
    var order: Order = .{};
    defer order.deinit(a);
    try order.sync(a, &.{ named("$1"), named("$2"), named("$3") });
    order.moveTo("$3", 0);
    try expectOrder(order, &.{ "$3", "$1", "$2" });
    try order.sync(a, &.{ named("$1"), named("$3"), named("$4"), named("$0") });
    try expectOrder(order, &.{ "$3", "$1", "$4", "$0" });
}

test "a session dropped on another takes its place" {
    const a = std.testing.allocator;
    var order: Order = .{};
    defer order.deinit(a);
    try order.sync(a, &.{ named("a"), named("b"), named("c") });
    order.moveTo("a", order.indexOf("c").?);
    try expectOrder(order, &.{ "b", "c", "a" });
    order.moveTo("a", order.indexOf("b").?);
    try expectOrder(order, &.{ "a", "b", "c" });
    order.step("a", -1);
    try expectOrder(order, &.{ "a", "b", "c" });
    order.step("a", 1);
    try expectOrder(order, &.{ "b", "a", "c" });
    order.step("c", 1);
    try expectOrder(order, &.{ "b", "a", "c" });
}

test "arranged sessions come first, unseen ones after" {
    const a = std.testing.allocator;
    var order: Order = .{};
    defer order.deinit(a);
    const sessions = [_]m.Session{ named("x"), named("y"), named("z") };
    try order.sync(a, sessions[0..2]);
    order.moveTo("y", 0);
    const listed = try order.arrange(a, &sessions);
    defer a.free(listed);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, listed);
}
