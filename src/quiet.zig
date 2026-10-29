// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Where tmm's control clients attach, so they do not change which session a
//! plain `tmux attach` picks.
//!
//! A control client cannot exist without a session, and tmux treats it like
//! any other client: the session counts as attached, so a plain `tmux attach`
//! passes it over for one nobody is on, and attaching marks the session as
//! just used, so after tmm exits a plain attach goes there. Left to tmux, a
//! control client takes the session the person used last, which is the one
//! their own attach wanted.
//!
//! So tmm attaches to the least recently used session no terminal is on, and
//! afterwards, if a terminal is on the session that was most recent before,
//! switches that terminal to the session it is already on. That marks it as
//! used again, newer than tmm's attach, and leaves the terminal where it was,
//! including its previous session for `switch-client -l`. Listing sessions
//! and clients does not mark anything, so deciding costs nothing.

const std = @import("std");
const cmstream = @import("cmstream.zig");
const Allocator = std.mem.Allocator;

/// The session line format `choose` reads: activity, then id.
pub const sessions_format = "#{session_activity} #{session_id}";
/// The client line format `choose` reads: control mode, session id, name.
pub const clients_format = "#{client_control_mode} #{session_id} #{client_name}";

pub const Choice = struct {
    /// The session to attach to.
    attach: []const u8,
    /// The session that was most recent before tmm attached, to mark as used
    /// again if a terminal is on it. Null when there is no other session.
    restore: ?[]const u8,
};

/// Decide from `list-sessions` and `list-clients` output in the formats
/// above. Slices borrow from `sessions`. Null when there are no sessions.
///
/// A session only control clients are on comes first, so tmm's second client
/// joins its first instead of taking another: the first one's attach has
/// just made its session the most recent. Otherwise the oldest session no
/// terminal is on, and the oldest of all when every session has one.
pub fn choose(sessions: []const u8, clients: []const u8) ?Choice {
    var oldest: ?Session = null;
    var oldest_free: ?Session = null;
    var held_by_control: ?Session = null;
    var newest: ?Session = null;
    var lines = std.mem.tokenizeScalar(u8, sessions, '\n');
    while (lines.next()) |line| {
        const s = Session.parse(line) orelse continue;
        if (oldest == null or s.activity < oldest.?.activity) oldest = s;
        const terminal = held(clients, s.id, false);
        if (!terminal and (oldest_free == null or s.activity < oldest_free.?.activity)) oldest_free = s;
        if (!terminal and held_by_control == null and held(clients, s.id, true)) held_by_control = s;
    }
    const pick = held_by_control orelse oldest_free orelse oldest orelse return null;
    const attach = pick.id;
    lines = std.mem.tokenizeScalar(u8, sessions, '\n');
    while (lines.next()) |line| {
        const s = Session.parse(line) orelse continue;
        if (std.mem.eql(u8, s.id, attach)) continue;
        if (newest == null or s.activity > newest.?.activity) newest = s;
    }
    return .{ .attach = attach, .restore = if (newest) |n| n.id else null };
}

/// A terminal on `session` in `list-clients` output, or null. Borrows.
pub fn terminalOn(clients: []const u8, session: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, clients, '\n');
    while (lines.next()) |line| {
        const c = Client.parse(line) orelse continue;
        if (!c.control and std.mem.eql(u8, c.session, session)) return c.name;
    }
    return null;
}

const Session = struct {
    activity: u64,
    id: []const u8,

    fn parse(line: []const u8) ?Session {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const activity = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch 0;
        return .{ .activity = activity, .id = fields.next() orelse return null };
    }
};

const Client = struct {
    control: bool,
    session: []const u8,
    name: []const u8,

    fn parse(line: []const u8) ?Client {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const control = fields.next() orelse return null;
        const session = fields.next() orelse return null;
        // A client name is a tty path, but take the rest in case it has spaces.
        const name = fields.rest();
        if (name.len == 0) return null;
        return .{ .control = std.mem.eql(u8, control, "1"), .session = session, .name = name };
    }
};

fn held(clients: []const u8, session: []const u8, control: bool) bool {
    var lines = std.mem.tokenizeScalar(u8, clients, '\n');
    while (lines.next()) |line| {
        const c = Client.parse(line) orelse continue;
        if (c.control == control and std.mem.eql(u8, c.session, session)) return true;
    }
    return false;
}

/// Open a control client attached as described above. When the server
/// cannot be asked, attaches wherever tmux puts it, as before.
pub fn open(alloc: Allocator, io: std.Io, opts: cmstream.Options) !*cmstream.Stream {
    const sessions = run(alloc, io, opts, &.{ "list-sessions", "-F", sessions_format });
    defer if (sessions) |s| alloc.free(s);
    const clients = run(alloc, io, opts, &.{ "list-clients", "-F", clients_format });
    defer if (clients) |c| alloc.free(c);
    const choice = choose(sessions orelse "", clients orelse "");

    var attach_opts = opts;
    if (choice) |c| attach_opts.session = c.attach;
    const stream = try cmstream.Stream.open(alloc, io, attach_opts);

    const restore = (choice orelse return stream).restore orelse return stream;
    // Asked again: a terminal that attached while tmm did is on the list now.
    const now = run(alloc, io, opts, &.{ "list-clients", "-F", clients_format }) orelse return stream;
    defer alloc.free(now);
    const terminal = terminalOn(now, restore) orelse return stream;
    if (run(alloc, io, opts, &.{ "switch-client", "-c", terminal, "-t", restore })) |out| alloc.free(out);
    return stream;
}

/// A one-shot tmux command's output, or null if it failed.
fn run(alloc: Allocator, io: std.Io, opts: cmstream.Options, args: []const []const u8) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.append(alloc, opts.tmux_bin) catch return null;
    if (opts.socket) |s| {
        argv.appendSlice(alloc, &.{ "-S", s }) catch return null;
    } else if (opts.label) |l| {
        argv.appendSlice(alloc, &.{ "-L", l }) catch return null;
    }
    argv.appendSlice(alloc, args) catch return null;
    const result = std.process.run(alloc, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
    }) catch return null;
    alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return null;
    }
    return result.stdout;
}

test "attaches to the oldest session no terminal is on, and restores the newest" {
    const sessions = "100 $0\n300 $1\n200 $2\n50 $3\n";
    const clients = "0 $3 /dev/ttys001\n";
    const c = choose(sessions, clients).?;
    try std.testing.expectEqualStrings("$0", c.attach);
    try std.testing.expectEqualStrings("$1", c.restore.?);
}

test "a second control client joins the first" {
    // The first one's attach made $0 the most recent.
    const sessions = "400 $0\n300 $1\n200 $2\n";
    const clients = "1 $0 client-1\n0 $1 /dev/ttys001\n";
    const c = choose(sessions, clients).?;
    try std.testing.expectEqualStrings("$0", c.attach);
    try std.testing.expectEqualStrings("$1", c.restore.?);
}

test "every session with a terminal on it: the oldest, and the newest restored" {
    const sessions = "100 $0\n300 $1\n";
    const clients = "0 $0 /dev/ttys001\n0 $1 /dev/ttys002\n";
    const c = choose(sessions, clients).?;
    try std.testing.expectEqualStrings("$0", c.attach);
    try std.testing.expectEqualStrings("$1", c.restore.?);
}

test "one session: attach to it, nothing to restore" {
    const c = choose("100 $0\n", "").?;
    try std.testing.expectEqualStrings("$0", c.attach);
    try std.testing.expect(c.restore == null);
    try std.testing.expect(choose("", "") == null);
}

test "terminalOn skips control clients" {
    const clients = "1 $1 client-1\n0 $1 /dev/ttys004\n";
    try std.testing.expectEqualStrings("/dev/ttys004", terminalOn(clients, "$1").?);
    try std.testing.expect(terminalOn(clients, "$2") == null);
}
