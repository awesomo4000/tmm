// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Incrementally maintained tmux state.
//!
//! Control-mode notifications carry only ids: `%window-add @1` says a window
//! appeared and nothing else — no name, no session, no panes. So applying an
//! event does one of two things:
//!
//!   1. **Updates the model directly**, when the event carries the new value
//!      (`%window-renamed @1 name`) or is purely a removal (`%window-close`).
//!   2. **Marks something dirty**, when filling it in needs a query. The owner
//!      of this state then issues one targeted query per dirty item instead of
//!      rebuilding everything.
//!
//! Nothing here performs IO; it is pure state plus a dirty set, so it is
//! unit-testable. `reconcile.zig` checks the result against a full query.
//!
//! Strings are owned by this module and freed on `deinit` or on removal, so
//! callers may hand it borrowed event slices.

const std = @import("std");
const control = @import("control.zig");
const m = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    alloc: Allocator,
    sessions: std.ArrayList(m.Session) = .empty,
    panes: std.ArrayList(m.Pane) = .empty,

    /// Window ids whose pane set or geometry must be re-queried.
    dirty_windows: std.ArrayList([]const u8) = .empty,
    /// Session ids whose metadata must be re-queried.
    dirty_sessions: std.ArrayList([]const u8) = .empty,
    /// Set when an event implies a change too broad to localise, or when the
    /// event stream was interrupted. The owner does a full collect and clears it.
    needs_full: bool = true,

    /// Pane ids that produced output since `clearOutput`. A pane that emitted
    /// nothing cannot have changed its screen, so its agent status need not be
    /// re-captured — which is where most of each pass's tmux queries go.
    output_panes: std.ArrayList([]const u8) = .empty,

    pub fn init(alloc: Allocator) State {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *State) void {
        for (self.sessions.items) |s| self.freeSession(s);
        self.sessions.deinit(self.alloc);
        for (self.panes.items) |p| self.freePane(p);
        self.panes.deinit(self.alloc);
        for (self.dirty_windows.items) |w| self.alloc.free(w);
        self.dirty_windows.deinit(self.alloc);
        for (self.dirty_sessions.items) |s| self.alloc.free(s);
        self.dirty_sessions.deinit(self.alloc);
        for (self.output_panes.items) |p| self.alloc.free(p);
        self.output_panes.deinit(self.alloc);
    }

    fn freeSession(self: *State, s: m.Session) void {
        self.alloc.free(s.id);
        self.alloc.free(s.name);
        self.alloc.free(s.path);
    }

    fn freePane(self: *State, p: m.Pane) void {
        self.alloc.free(p.session);
        self.alloc.free(p.window);
        self.alloc.free(p.id);
        self.alloc.free(p.cwd);
        self.alloc.free(p.command);
    }

    fn markWindow(self: *State, id: []const u8) !void {
        for (self.dirty_windows.items) |w| if (std.mem.eql(u8, w, id)) return;
        try self.dirty_windows.append(self.alloc, try self.alloc.dupe(u8, id));
    }

    fn markSession(self: *State, id: []const u8) !void {
        for (self.dirty_sessions.items) |s| if (std.mem.eql(u8, s, id)) return;
        try self.dirty_sessions.append(self.alloc, try self.alloc.dupe(u8, id));
    }

    /// Apply one control-mode event. Returns true when the caller should
    /// produce a fresh view (anything the UI could notice changed).
    pub fn apply(self: *State, ev: control.Event) !bool {
        switch (ev) {
            // Window names are not in the model: panes key off window ids, so a
            // rename changes nothing stored here. Deliberately a no-op rather
            // than marking the window dirty, which would cost a query for
            // information nothing reads. Revisit when windows gain names.
            //
            // The two variants cannot share a capture: they are distinct
            // anonymous struct types even though their fields match.
            .window_renamed, .unlinked_window_renamed => return false,
            .session_renamed => |x| {
                for (self.sessions.items) |*s| {
                    if (!std.mem.eql(u8, s.id, x.session)) continue;
                    const name = try self.alloc.dupe(u8, x.name);
                    self.alloc.free(s.name);
                    s.name = name;
                    return true;
                }
                try self.markSession(x.session);
                return true;
            },

            // Pure removals: drop what we hold, no query.
            .window_close, .unlinked_window_close => |id| {
                var i: usize = 0;
                var removed = false;
                while (i < self.panes.items.len) {
                    if (std.mem.eql(u8, self.panes.items[i].window, id)) {
                        self.freePane(self.panes.orderedRemove(i));
                        removed = true;
                        continue;
                    }
                    i += 1;
                }
                return removed;
            },

            // Need a query to learn the details.
            .window_add, .unlinked_window_add => |id| {
                try self.markWindow(id);
                return true;
            },
            .layout_change => |l| {
                // Panes may have been added, removed or resized; the layout
                // string has geometry but not cwd or command.
                try self.markWindow(l.window);
                return true;
            },
            .window_pane_changed => |x| {
                try self.markWindow(x.window);
                return true;
            },

            // Session-level changes we cannot localise.
            .sessions_changed, .session_changed, .client_session_changed => {
                self.needs_full = true;
                return true;
            },
            .session_window_changed => |x| {
                try self.markSession(x.session);
                try self.markWindow(x.window);
                return true;
            },

            // The stream ended or we lost sync; only a full query is safe.
            .exit => {
                self.needs_full = true;
                return true;
            },

            // Pane bytes change no structure, but they do mean that pane's
            // screen moved, which is what decides whether its agent status
            // needs re-capturing.
            .output => |o| {
                try self.markOutput(o.pane);
                return false;
            },
            .extended_output => |o| {
                try self.markOutput(o.pane);
                return false;
            },

            // Our own command replies change nothing.
            .reply_begin, .reply_line, .reply_end => return false,

            else => return false,
        }
    }

    /// Replace everything from a full query and clear all dirt.
    pub fn adopt(self: *State, sessions: []const m.Session, panes: []const m.Pane) !void {
        for (self.sessions.items) |s| self.freeSession(s);
        self.sessions.clearRetainingCapacity();
        for (self.panes.items) |p| self.freePane(p);
        self.panes.clearRetainingCapacity();
        for (self.dirty_windows.items) |w| self.alloc.free(w);
        self.dirty_windows.clearRetainingCapacity();
        for (self.dirty_sessions.items) |s| self.alloc.free(s);
        self.dirty_sessions.clearRetainingCapacity();

        for (sessions) |s| try self.sessions.append(self.alloc, .{
            .id = try self.alloc.dupe(u8, s.id),
            .name = try self.alloc.dupe(u8, s.name),
            .path = try self.alloc.dupe(u8, s.path),
        });
        for (panes) |p| try self.panes.append(self.alloc, .{
            .session = try self.alloc.dupe(u8, p.session),
            .window = try self.alloc.dupe(u8, p.window),
            .id = try self.alloc.dupe(u8, p.id),
            .cwd = try self.alloc.dupe(u8, p.cwd),
            .command = try self.alloc.dupe(u8, p.command),
            .agent = p.agent,
            .state = p.state,
            .status = p.status,
        });
        self.needs_full = false;
    }

    fn markOutput(self: *State, pane: []const u8) !void {
        for (self.output_panes.items) |p| if (std.mem.eql(u8, p, pane)) return;
        try self.output_panes.append(self.alloc, try self.alloc.dupe(u8, pane));
    }

    /// Record that a pane emitted output. Public because the control reader
    /// runs in another task and forwards pane ids rather than payloads.
    pub fn noteOutput(self: *State, pane: []const u8) !void {
        return self.markOutput(pane);
    }

    pub fn hadOutput(self: *const State, pane: []const u8) bool {
        for (self.output_panes.items) |p| if (std.mem.eql(u8, p, pane)) return true;
        return false;
    }

    /// Called once a pass has consumed the output marks.
    pub fn clearOutput(self: *State) void {
        for (self.output_panes.items) |p| self.alloc.free(p);
        self.output_panes.clearRetainingCapacity();
    }

    pub fn isDirty(self: *const State) bool {
        return self.needs_full or
            self.dirty_windows.items.len > 0 or
            self.dirty_sessions.items.len > 0;
    }
};

const testing = std.testing;

fn testPane(id: []const u8, window: []const u8) m.Pane {
    return .{ .session = "$0", .window = window, .id = id, .cwd = "/a", .command = "bash", .agent = "", .state = "", .status = "" };
}

test "a fresh state demands a full query" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try testing.expect(st.needs_full);
    try testing.expect(st.isDirty());
}

test "adopting a full query clears all dirt" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    const sessions = [_]m.Session{.{ .id = "$0", .name = "alpha", .path = "/a" }};
    const panes = [_]m.Pane{testPane("%1", "@0")};
    try st.adopt(&sessions, &panes);
    try testing.expect(!st.isDirty());
    try testing.expectEqual(@as(usize, 1), st.panes.items.len);
}

test "window close drops that window's panes without a query" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    const panes = [_]m.Pane{ testPane("%1", "@0"), testPane("%2", "@1"), testPane("%3", "@1") };
    try st.adopt(&.{}, &panes);
    try testing.expect(try st.apply(.{ .window_close = "@1" }));
    try testing.expectEqual(@as(usize, 1), st.panes.items.len);
    try testing.expectEqualStrings("%1", st.panes.items[0].id);
    // A removal needs no follow-up query.
    try testing.expect(!st.isDirty());
}

test "window add marks the window dirty rather than guessing" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{});
    try testing.expect(try st.apply(.{ .window_add = "@7" }));
    try testing.expectEqual(@as(usize, 1), st.dirty_windows.items.len);
    try testing.expectEqualStrings("@7", st.dirty_windows.items[0]);
    try testing.expect(st.isDirty());
}

test "repeated events do not duplicate dirty entries" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{});
    _ = try st.apply(.{ .window_add = "@7" });
    _ = try st.apply(.{ .layout_change = .{ .window = "@7", .layout = "x", .visible = "x", .flags = "*" } });
    _ = try st.apply(.{ .window_pane_changed = .{ .window = "@7", .pane = "%9" } });
    try testing.expectEqual(@as(usize, 1), st.dirty_windows.items.len);
}

test "session rename is applied in place" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    const sessions = [_]m.Session{.{ .id = "$0", .name = "old", .path = "/a" }};
    try st.adopt(&sessions, &.{});
    try testing.expect(try st.apply(.{ .session_renamed = .{ .session = "$0", .name = "new" } }));
    try testing.expectEqualStrings("new", st.sessions.items[0].name);
    // Applied directly, so no query is owed.
    try testing.expectEqual(@as(usize, 0), st.dirty_sessions.items.len);
}

test "renaming an unknown session falls back to a query" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{});
    _ = try st.apply(.{ .session_renamed = .{ .session = "$9", .name = "new" } });
    try testing.expectEqual(@as(usize, 1), st.dirty_sessions.items.len);
}

test "pane output marks that pane, not the structure" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{testPane("%1", "@0")});
    try testing.expect(!try st.apply(.{ .output = .{ .pane = "%1", .escaped = "hello" } }));
    try testing.expect(!st.isDirty());
    try testing.expect(st.hadOutput("%1"));
    try testing.expect(!st.hadOutput("%2"));
    st.clearOutput();
    try testing.expect(!st.hadOutput("%1"));
}

test "repeated output from one pane records it once" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{});
    for (0..5) |_| _ = try st.apply(.{ .output = .{ .pane = "%1", .escaped = "x" } });
    try testing.expectEqual(@as(usize, 1), st.output_panes.items.len);
}

test "sessions-changed and exit escalate to a full query" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.adopt(&.{}, &.{});
    try testing.expect(try st.apply(.sessions_changed));
    try testing.expect(st.needs_full);
    try st.adopt(&.{}, &.{});
    try testing.expect(try st.apply(.{ .exit = "" }));
    try testing.expect(st.needs_full);
}
