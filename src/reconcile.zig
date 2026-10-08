// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Compares an incrementally-maintained view of tmux state against a freshly
//! queried one. Full queries are cheap now that they ride a control client
//! instead of a fork and exec each, so a full query is affordable as an oracle:
//! in tests after every operation, and at a low rate at runtime to catch drift.
//!
//! Only **structural** fields are compared — session, window, pane id, cwd and
//! command — because those are derivable from tmux and must match exactly.
//! Agent fields (state, status, completion, unread, interrupted) are *sampled*:
//! they come from screen inspection and from rules that need two consecutive
//! observations, so two samples taken moments apart legitimately differ and
//! comparing them would report drift that is not drift.
//!
//! Comparison is order-insensitive: tmux returns its own ordering and an
//! incremental model will accumulate a different one.

const std = @import("std");
const m = @import("model.zig");

pub const View = struct {
    sessions: []const m.Session = &.{},
    panes: []const m.Pane = &.{},
};

pub const Mismatch = struct {
    pub const Kind = enum {
        session_missing,
        session_unexpected,
        session_differs,
        pane_missing,
        pane_unexpected,
        pane_differs,
    };
    kind: Kind,
    /// tmux id of the offending object.
    id: []const u8,
    /// Field name for a `_differs` kind, empty otherwise.
    field: []const u8 = "",
    expected: []const u8 = "",
    actual: []const u8 = "",
};

fn lessById(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn findSession(list: []const m.Session, id: []const u8) ?m.Session {
    for (list) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

fn findPane(list: []const m.Pane, id: []const u8) ?m.Pane {
    for (list) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

/// Structural differences between `incremental` and `queried`. Empty means the
/// incremental model is faithful. Caller owns the result; the strings inside
/// borrow from the inputs.
pub fn diff(alloc: std.mem.Allocator, incremental: View, queried: View) ![]Mismatch {
    var out: std.ArrayList(Mismatch) = .empty;
    errdefer out.deinit(alloc);

    for (queried.sessions) |want| {
        const got = findSession(incremental.sessions, want.id) orelse {
            try out.append(alloc, .{ .kind = .session_missing, .id = want.id });
            continue;
        };
        if (!std.mem.eql(u8, got.name, want.name)) try out.append(alloc, .{
            .kind = .session_differs,
            .id = want.id,
            .field = "name",
            .expected = want.name,
            .actual = got.name,
        });
        if (!std.mem.eql(u8, got.path, want.path)) try out.append(alloc, .{
            .kind = .session_differs,
            .id = want.id,
            .field = "path",
            .expected = want.path,
            .actual = got.path,
        });
    }
    for (incremental.sessions) |got| {
        if (findSession(queried.sessions, got.id) == null)
            try out.append(alloc, .{ .kind = .session_unexpected, .id = got.id });
    }

    for (queried.panes) |want| {
        const got = findPane(incremental.panes, want.id) orelse {
            try out.append(alloc, .{ .kind = .pane_missing, .id = want.id });
            continue;
        };
        // Structural only; see the module comment on sampled fields.
        const fields = [_]struct { name: []const u8, want: []const u8, got: []const u8 }{
            .{ .name = "session", .want = want.session, .got = got.session },
            .{ .name = "window", .want = want.window, .got = got.window },
            .{ .name = "cwd", .want = want.cwd, .got = got.cwd },
            .{ .name = "command", .want = want.command, .got = got.command },
        };
        for (fields) |f| {
            if (!std.mem.eql(u8, f.want, f.got)) try out.append(alloc, .{
                .kind = .pane_differs,
                .id = want.id,
                .field = f.name,
                .expected = f.want,
                .actual = f.got,
            });
        }
    }
    for (incremental.panes) |got| {
        if (findPane(queried.panes, got.id) == null)
            try out.append(alloc, .{ .kind = .pane_unexpected, .id = got.id });
    }

    return out.toOwnedSlice(alloc);
}

/// Human-readable one-liner, for a log line or a test failure.
pub fn describe(alloc: std.mem.Allocator, mismatch: Mismatch) ![]u8 {
    return switch (mismatch.kind) {
        .session_differs, .pane_differs => std.fmt.allocPrint(
            alloc,
            "{s} {s}: {s} queried={s} incremental={s}",
            .{ @tagName(mismatch.kind), mismatch.id, mismatch.field, mismatch.expected, mismatch.actual },
        ),
        else => std.fmt.allocPrint(alloc, "{s} {s}", .{ @tagName(mismatch.kind), mismatch.id }),
    };
}

const testing = std.testing;

fn pane(id: []const u8, session: []const u8, window: []const u8, cwd: []const u8, cmd: []const u8) m.Pane {
    return .{ .session = session, .window = window, .id = id, .cwd = cwd, .command = cmd, .agent = "", .state = "", .status = "" };
}

test "identical views do not diverge" {
    const panes = [_]m.Pane{ pane("%1", "$0", "@0", "/a", "bash"), pane("%2", "$0", "@1", "/b", "vim") };
    const sessions = [_]m.Session{.{ .id = "$0", .name = "alpha", .path = "/a" }};
    const d = try diff(testing.allocator, .{ .sessions = &sessions, .panes = &panes }, .{ .sessions = &sessions, .panes = &panes });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "ordering does not matter" {
    const a = [_]m.Pane{ pane("%1", "$0", "@0", "/a", "bash"), pane("%2", "$0", "@1", "/b", "vim") };
    const b = [_]m.Pane{ pane("%2", "$0", "@1", "/b", "vim"), pane("%1", "$0", "@0", "/a", "bash") };
    const d = try diff(testing.allocator, .{ .panes = &a }, .{ .panes = &b });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "a pane the incremental model missed is reported" {
    const incremental = [_]m.Pane{pane("%1", "$0", "@0", "/a", "bash")};
    const queried = [_]m.Pane{ pane("%1", "$0", "@0", "/a", "bash"), pane("%2", "$0", "@1", "/b", "vim") };
    const d = try diff(testing.allocator, .{ .panes = &incremental }, .{ .panes = &queried });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqual(Mismatch.Kind.pane_missing, d[0].kind);
    try testing.expectEqualStrings("%2", d[0].id);
}

test "a pane the incremental model kept after death is reported" {
    const incremental = [_]m.Pane{ pane("%1", "$0", "@0", "/a", "bash"), pane("%9", "$0", "@0", "/x", "zsh") };
    const queried = [_]m.Pane{pane("%1", "$0", "@0", "/a", "bash")};
    const d = try diff(testing.allocator, .{ .panes = &incremental }, .{ .panes = &queried });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqual(Mismatch.Kind.pane_unexpected, d[0].kind);
}

test "a stale field is reported with both values" {
    const incremental = [_]m.Pane{pane("%1", "$0", "@0", "/stale", "bash")};
    const queried = [_]m.Pane{pane("%1", "$0", "@0", "/fresh", "bash")};
    const d = try diff(testing.allocator, .{ .panes = &incremental }, .{ .panes = &queried });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqualStrings("cwd", d[0].field);
    try testing.expectEqualStrings("/fresh", d[0].expected);
    try testing.expectEqualStrings("/stale", d[0].actual);
}

test "sampled agent fields are deliberately ignored" {
    var a = pane("%1", "$0", "@0", "/a", "bash");
    var b = pane("%1", "$0", "@0", "/a", "bash");
    a.state = "working";
    a.completion = 7;
    a.unread = true;
    b.state = "idle";
    b.completion = 0;
    const incremental = [_]m.Pane{a};
    const queried = [_]m.Pane{b};
    const d = try diff(testing.allocator, .{ .panes = &incremental }, .{ .panes = &queried });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "a moved pane is reported as a field difference, not a replacement" {
    const incremental = [_]m.Pane{pane("%1", "$0", "@0", "/a", "bash")};
    const queried = [_]m.Pane{pane("%1", "$0", "@3", "/a", "bash")};
    const d = try diff(testing.allocator, .{ .panes = &incremental }, .{ .panes = &queried });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqualStrings("window", d[0].field);
}

test "session rename and missing session are both caught" {
    const inc = [_]m.Session{.{ .id = "$0", .name = "old", .path = "/a" }};
    const qry = [_]m.Session{ .{ .id = "$0", .name = "new", .path = "/a" }, .{ .id = "$1", .name = "beta", .path = "/b" } };
    const d = try diff(testing.allocator, .{ .sessions = &inc }, .{ .sessions = &qry });
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 2), d.len);
}
