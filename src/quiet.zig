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
//!
//! tmux ranks sessions by activity to the microsecond, but formats show it
//! only to the second, and sessions used within the same second are the
//! usual case at startup: tmm and the attach it must not disturb are started
//! together. So the sessions are asked for in tmux's own order, newest first
//! (`list-sessions -O activity`, tmux 3.7 and later), and a tie in the
//! seconds is broken by that order. Before 3.7 the list is in name order, and
//! tmux is asked for the one session it holds newest, which is moved to the
//! front: that is the one a tie must not get wrong. Ties among the rest are
//! broken by name.

const std = @import("std");
const cmstream = @import("cmstream.zig");
const tmux = @import("tmux.zig");
const Allocator = std.mem.Allocator;

/// The session line format `choose` reads: activity, then id.
pub const sessions_format = "#{session_activity} #{session_id}";
/// The listing `choose` wants: sessions newest first, by tmux's own clock.
const sessions_newest_first = [_][]const u8{ "list-sessions", "-O", "activity", "-F", sessions_format };
/// The same, for a tmux older than 3.7, which has no `-O`.
const sessions_unordered = [_][]const u8{ "list-sessions", "-F", sessions_format };
/// With no target and no pane to go by, tmux resolves the newest session.
const newest_session = [_][]const u8{ "display-message", "-p", "#{session_id}" };
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
/// above, the sessions newest first where tmux can say. Within one second of
/// activity an earlier line is the newer session. Slices borrow from
/// `sessions`. Null when there are no sessions.
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
        // `<=`: on a tie the later line is the older session.
        if (oldest == null or s.activity <= oldest.?.activity) oldest = s;
        const terminal = held(clients, s.id, false);
        if (!terminal and (oldest_free == null or s.activity <= oldest_free.?.activity)) oldest_free = s;
        if (!terminal and held_by_control == null and held(clients, s.id, true)) held_by_control = s;
    }
    const pick = held_by_control orelse oldest_free orelse oldest orelse return null;
    const attach = pick.id;
    lines = std.mem.tokenizeScalar(u8, sessions, '\n');
    while (lines.next()) |line| {
        const s = Session.parse(line) orelse continue;
        if (std.mem.eql(u8, s.id, attach)) continue;
        // `>`: on a tie the earlier line is the newer session.
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
/// `environ` is tmm's own environment.
pub fn open(alloc: Allocator, io: std.Io, environ: std.process.Environ, opts: cmstream.Options) !*cmstream.Stream {
    const sessions = run(alloc, io, opts, null, &sessions_newest_first) orelse
        newestFirst(alloc, io, environ, opts);
    defer if (sessions) |s| alloc.free(s);
    const clients = run(alloc, io, opts, null, &.{ "list-clients", "-F", clients_format });
    defer if (clients) |c| alloc.free(c);
    const choice = choose(sessions orelse "", clients orelse "");

    var attach_opts = opts;
    if (choice) |c| attach_opts.session = c.attach;
    const stream = try cmstream.Stream.open(alloc, io, attach_opts);

    const restore = (choice orelse return stream).restore orelse return stream;
    // Asked again: a terminal that attached while tmm did is on the list now.
    const now = run(alloc, io, opts, null, &.{ "list-clients", "-F", clients_format }) orelse return stream;
    defer alloc.free(now);
    const terminal = terminalOn(now, restore) orelse return stream;
    if (run(alloc, io, opts, null, &.{ "switch-client", "-c", terminal, "-t", restore })) |out| alloc.free(out);
    return stream;
}

/// For a tmux older than 3.7: the sessions in name order, with the one tmux
/// holds newest moved to the front. Null when they cannot be listed.
fn newestFirst(alloc: Allocator, io: std.Io, environ: std.process.Environ, opts: cmstream.Options) ?[]u8 {
    const listed = run(alloc, io, opts, null, &sessions_unordered) orelse return null;
    var env = environ.createMap(alloc) catch return listed;
    defer env.deinit();
    // tmm runs in a pane, and tmux takes a command from a pane to mean that
    // pane's session. It goes by TMUX_PANE, or by standard input being the
    // pane's terminal, which it is not here: tmux is run with it on /dev/null.
    _ = env.swapRemove("TMUX_PANE");
    const newest = run(alloc, io, opts, &env, &newest_session) orelse return listed;
    defer alloc.free(newest);
    const moved = putFirst(alloc, listed, std.mem.trim(u8, newest, " \n")) catch return listed;
    alloc.free(listed);
    return moved;
}

/// `sessions` with the line for session `id` moved to the front. Owned.
fn putFirst(alloc: Allocator, sessions: []const u8, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, sessions.len + 1);
    for ([_]bool{ true, false }) |first| {
        var lines = std.mem.tokenizeScalar(u8, sessions, '\n');
        while (lines.next()) |line| {
            const s = Session.parse(line) orelse continue;
            if (std.mem.eql(u8, s.id, id) != first) continue;
            out.appendSliceAssumeCapacity(line);
            out.appendAssumeCapacity('\n');
        }
    }
    return out.toOwnedSlice(alloc);
}

/// A one-shot tmux command's output, or null if it failed. `env` replaces
/// tmm's environment when given.
fn run(alloc: Allocator, io: std.Io, opts: cmstream.Options, env: ?*const std.process.Environ.Map, args: []const []const u8) ?[]u8 {
    var server = tmux.Server.init(alloc, io, opts.server);
    server.environ_map = env;
    var result = server.exec(args) catch return null;
    if (!result.success()) {
        result.deinit();
        return null;
    }
    alloc.free(result.stderr);
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

test "within one second, the order of the lines decides" {
    // All used in the same second; tmux listed them newest first, so $2 is
    // the one a plain attach wants and $0 the one nobody has touched longest.
    const sessions = "500 $2\n500 $1\n500 $0\n";
    const c = choose(sessions, "0 $2 /dev/ttys001\n").?;
    try std.testing.expectEqualStrings("$0", c.attach);
    try std.testing.expectEqualStrings("$2", c.restore.?);
    // The terminal on the oldest instead: attach to the oldest free one.
    const d = choose(sessions, "0 $0 /dev/ttys001\n").?;
    try std.testing.expectEqualStrings("$1", d.attach);
    try std.testing.expectEqualStrings("$2", d.restore.?);
}

test "before tmux 3.7, the newest session goes first and wins the tie" {
    // Name order, all in one second, and tmux says $1 is the newest.
    const moved = try putFirst(std.testing.allocator, "500 $0\n500 $1\n500 $2\n", "$1");
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("500 $1\n500 $0\n500 $2\n", moved);
    const c = choose(moved, "0 $1 /dev/ttys001\n").?;
    try std.testing.expectEqualStrings("$2", c.attach);
    try std.testing.expectEqualStrings("$1", c.restore.?);
}

test "terminalOn skips control clients" {
    const clients = "1 $1 client-1\n0 $1 /dev/ttys004\n";
    try std.testing.expectEqualStrings("/dev/ttys004", terminalOn(clients, "$1").?);
    try std.testing.expect(terminalOn(clients, "$2") == null);
}
