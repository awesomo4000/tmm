// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const m = @import("model.zig");
const backend = @import("backend.zig");
const reported_opt = @import("reported.zig");
const tmux = @import("libtmux");
pub const Server = struct { name: []const u8, options: tmux.ServerOptions };
pub const Action = union(enum) { server: usize, display: usize, session: usize, fold: usize, pane: usize, new_session, blink };

/// Columns the fold arrow and the space after it take at the start of a
/// session row; a click inside them folds rather than selects.
pub const fold_width = 2;

/// What a program in a pane said about itself (OSC 7501, carried to tmm as
/// the `@tmm_status` pane option), as opposed to what reading its screen
/// suggested.
///
/// The title is copied into the struct rather than referenced, so a record
/// never borrows from the snapshot it was parsed out of. The label beside the
/// indicator still comes from the pane's command.
pub const Reported = struct {
    /// Longest title a row has space for beside the name and the indicator.
    pub const title_max = 24;

    state: enum { idle, working, done, blocked, @"error" },
    kind: ?enum { permission, question, auth } = null,
    progress: ?u8 = null,
    /// What the program said it is working on, copied in. Empty when it said
    /// nothing, which is the common case.
    title_buf: [title_max]u8 = @splat(0),
    title_len: u8 = 0,

    pub fn title(self: *const Reported) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    /// The symbol and colour for a reported state, in the vocabulary the
    /// inferred states already use, plus a mark for `error`, which screen
    /// detection has no way to recognise.
    pub fn indicator(self: Reported) m.Indicator {
        return switch (self.state) {
            .working => .{ .symbol = "●", .color = 6 },
            .blocked => .{ .symbol = "!", .color = 3 },
            .done => .{ .symbol = "✓", .color = 2 },
            .idle => .{ .symbol = "○", .color = 8 },
            .@"error" => .{ .symbol = "✗", .color = 1 },
        };
    }
};

pub const Row = struct {
    text: []const u8,
    key: []const u8 = "",
    action: ?Action = null,
    color: u8 = 7,
    active: bool = false,
    heading: bool = false,
    /// Drawn dim after the text, for what is useful but not the point: a
    /// pane's directory.
    detail: []const u8 = "",
    /// The status glyph inside `text`, drawn alone in `symbol_color` so the
    /// name beside it can stay readable when the state is a dim one.
    symbol: []const u8 = "",
    symbol_color: u8 = 7,
    /// The process name inside `text`, drawn alone in `name_rgb`: a colour
    /// per agent, so which program a row is reads at a glance.
    name: []const u8 = "",
    name_rgb: ?[3]u8 = null,
    /// A folded session holding a finished result nobody has looked at, so
    /// its name says so in place of the rows it hides.
    done: bool = false,
};
/// Beside the selected server and display.
pub const entry_mark = "➤";
/// Ends the selected display's row; clicking it blinks that display.
pub const blink_mark = "✶";

pub fn rows(a: std.mem.Allocator, servers: []const Server, current: usize, snapshot: ?*backend.Snapshot, target: ?backend.Request, label: ?[]const u8, home: ?[]const u8, folded: *const std.StringHashMapUnmanaged(void)) ![]Row {
    var list: std.ArrayList(Row) = .empty;
    try list.append(a, .{ .text = "servers", .heading = true });
    // Servers and displays are indented like panes, with an arrow beside
    // the selected one.
    for (servers, 0..) |server, i| try list.append(a, .{
        .text = try std.fmt.allocPrint(a, "{s} {s}", .{ if (i == current) entry_mark else " ", server.name }),
        .key = try std.fmt.allocPrint(a, "server:{d}", .{i}),
        .action = .{ .server = i },
        .active = i == current,
    });
    try list.appendSlice(a, &.{ .{ .text = "" }, .{ .text = "displays", .heading = true } });
    if (snapshot) |s| {
        for (s.clients, 0..) |client, i| {
            var name = client.session;
            for (s.sessions) |session| if (std.mem.eql(u8, session.id, client.session)) {
                name = session.name;
                break;
            };
            const active = if (target) |t| client.same(t.client) else false;
            var display_name: []const u8 = client.terminal orelse std.fs.path.basename(client.name);
            if (client.terminal) |terminal| {
                var count: usize = 0;
                for (s.clients) |other| if (other.terminal) |owner| {
                    if (std.mem.eql(u8, owner, terminal)) count += 1;
                };
                if (count > 1) display_name = try std.fmt.allocPrint(a, "{s} ({s})", .{ terminal, std.fs.path.basename(client.name) });
            }

            try list.append(a, .{
                // The selected display ends in the blink button.
                .text = try std.fmt.allocPrint(a, "{s} {s} : {s}{s}", .{
                    if (active) entry_mark else " ",
                    if (active and label != null) label.? else display_name,
                    name,
                    if (active) " " ++ blink_mark else "",
                }),
                .key = try std.fmt.allocPrint(a, "display:{s}:{s}:{s}", .{ client.name, client.pid, client.created }),
                .action = .{ .display = i },
                .active = active,
            });
        }
        if (s.clients.len == 0) try list.append(a, .{ .text = "no attached displays", .color = 8 });
    }
    try list.appendSlice(a, &.{ .{ .text = "" }, .{ .text = "sessions", .heading = true, .key = "new-session", .action = .new_session } });
    if (snapshot) |s| {
        for (s.sessions, 0..) |session, i| {
            var active = false;
            if (target) |t| for (s.clients) |client| {
                if (client.same(t.client) and std.mem.eql(u8, client.session, session.id)) active = true;
            };
            const fold = folded.contains(session.id);
            const where = sessionDirectory(s.panes, session.id);
            try list.append(a, .{ .text = "" });
            const session_row = list.items.len;
            try list.append(a, .{
                .text = try std.fmt.allocPrint(a, "{s} {s}", .{ if (fold) "▶" else "▼", session.name }),
                .key = try std.fmt.allocPrint(a, "session:{s}", .{session.id}),
                .action = .{ .session = i },
                .active = active,
                .detail = try tilde(a, home, where),
            });
            for (s.panes, 0..) |pane, pane_index| {
                if (!std.mem.eql(u8, pane.session, session.id)) continue;
                // What the program said beats what its screen suggested.
                // The detector says as much about itself: quiet output is
                // never a completion, a transition between polls is missed,
                // and an unrecognised screen stays unknown. A report has none
                // of those failure modes. It arrives as a pane option rather
                // than in band, because tmm reads tmux over control mode and
                // never sees a pane's own bytes; see src/reported.zig.
                // As it stands now rather than as written: a record whose
                // writer is gone, with the pane back at its prompt, ends.
                const said = reported_opt.current(pane.reported, pane.at_prompt);
                const state = if (said) |r| r.indicator() else m.agentIndicator(pane.state);
                const is_agent = pane.agent.len > 0 or said != null;
                if (fold) {
                    if (is_agent and (std.mem.eql(u8, state.symbol, "✓") or pane.unread)) list.items[session_row].done = true;
                    continue;
                }
                const pane_active = active and std.mem.eql(u8, pane.id, s.focused_pane);
                const marker = if (pane_active) "▸" else " ";
                // A reported record is current by construction, so the
                // unread mark, which exists because an inferred completion
                // may be stale, is not added to one.
                const name = if (pane.agent.len > 0) pane.agent else if (pane.command.len > 0) pane.command else "shell";
                const text = if (said) |r| blk: {
                    if (r.progress) |percent| break :blk try std.fmt.allocPrint(
                        a,
                        "{s}   {s} {s} {d}%",
                        .{ marker, state.symbol, name, percent },
                    );
                    if (r.kind) |kind| break :blk try std.fmt.allocPrint(
                        a,
                        "{s}   {s} {s} ({s})",
                        .{ marker, state.symbol, name, @tagName(kind) },
                    );
                    // Below progress and the blocked kind, because both of
                    // those are more urgent than what it happens to be doing.
                    // This is what a program can say during long work when it
                    // has no fraction to report -- an agent hook knows the
                    // tool that is running but never how many will run.
                    if (r.title().len > 0) break :blk try std.fmt.allocPrint(
                        a,
                        "{s}   {s} {s} {s}",
                        .{ marker, state.symbol, name, r.title() },
                    );
                    break :blk try std.fmt.allocPrint(a, "{s}   {s} {s}", .{ marker, state.symbol, name });
                } else if (is_agent)
                    try std.fmt.allocPrint(a, "{s} {s}{s} {s}", .{ marker, if (pane.unread and !std.mem.eql(u8, pane.state, "done")) "✓ " else "", state.symbol, pane.agent })
                else
                    try std.fmt.allocPrint(a, "{s}   {s}", .{ marker, if (pane.command.len > 0) pane.command else "shell" });
                const pane_key = try std.fmt.allocPrint(a, "pane:{s}:{s}", .{ pane.session, pane.id });
                // Only a pane that has wandered off says where it is; the rest
                // are where the session row says.
                const path = if (std.mem.eql(u8, pane.cwd, where)) "" else try tilde(a, home, pane.cwd);
                try list.append(a, .{
                    .text = text,
                    .detail = path,
                    .key = pane_key,
                    .action = .{ .pane = pane_index },
                    // A dim state dims its symbol, not the name: a row of idle
                    // agents has to stay readable.
                    .color = if (is_agent and state.color != 8) state.color else 7,
                    .symbol = if (is_agent) state.symbol else "",
                    .symbol_color = state.color,
                    .name = name,
                    .name_rgb = processColor(name),
                    .active = pane_active,
                });
            }
        }
    }
    return list.toOwnedSlice(a);
}

/// A process name's colour: one per agent, muted so the status symbols stay
/// the loudest thing on a row, and a soft slate for everything else rather
/// than plain white. Flat colours, never the gradient, so a name is the same
/// colour wherever its row is.
pub fn processColor(name: []const u8) [3]u8 {
    const agents = .{
        .{ "claude", .{ 204, 122, 88 } },
        .{ "codex", .{ 120, 168, 186 } },
        .{ "gemini", .{ 128, 150, 222 } },
        .{ "opencode", .{ 176, 156, 210 } },
        .{ "aider", .{ 150, 186, 120 } },
        .{ "omp", .{ 196, 172, 118 } },
        .{ "pi", .{ 196, 172, 118 } },
    };
    inline for (agents) |agent| if (std.mem.eql(u8, name, agent[0])) return agent[1];
    return .{ 176, 182, 200 };
}

/// Where a session's panes are, which by habit is one directory: the one most
/// of them share, the first pane's on a tie. tmux's own session path is not
/// it, because that is only where the session was created.
fn sessionDirectory(panes: []const m.Pane, session: []const u8) []const u8 {
    var best: []const u8 = "";
    var best_count: usize = 0;
    for (panes, 0..) |pane, i| {
        if (!std.mem.eql(u8, pane.session, session)) continue;
        var count: usize = 0;
        for (panes[i..]) |other| {
            if (std.mem.eql(u8, other.session, session) and std.mem.eql(u8, other.cwd, pane.cwd)) count += 1;
        }
        if (count > best_count) {
            best = pane.cwd;
            best_count = count;
        }
    }
    return best;
}

/// A path with the home directory written as `~`.
fn tilde(a: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]const u8 {
    if (home) |h| if (h.len > 0 and std.mem.startsWith(u8, path, h) and (path.len == h.len or path[h.len] == '/')) {
        return std.fmt.allocPrint(a, "~{s}", .{path[h.len..]});
    };
    return path;
}

test "a session's directory is the one most of its panes share" {
    const pane: m.Pane = .{ .session = "$1", .window = "@1", .id = "%1", .cwd = "/a", .command = "", .agent = "", .state = "", .status = "" };
    var b = pane;
    b.cwd = "/b";
    var other = pane;
    other.session = "$2";
    other.cwd = "/c";
    try std.testing.expectEqualStrings("/b", sessionDirectory(&.{ pane, b, other, b }, "$1"));
    try std.testing.expectEqualStrings("/a", sessionDirectory(&.{ pane, b }, "$1"));
    try std.testing.expectEqualStrings("/c", sessionDirectory(&.{ pane, other }, "$2"));
}

/// Discover sockets only in tmux's conventional per-user directory. Custom
/// socket paths are explicit CLI entries; never traverse arbitrary directories.
pub fn discover(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, environ: std.process.Environ, list: *std.ArrayList(Server)) !void {
    const directory = try std.fmt.allocPrint(a, "{s}/tmux-{d}", .{ env.get("TMUX_TMPDIR") orelse "/tmp", std.posix.system.getuid() });
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .unix_domain_socket or std.mem.eql(u8, entry.name, "default")) continue;
        const path = try std.fs.path.join(a, &.{ directory, entry.name });
        var connection = backend.Connection.init(a, io, environ, .{ .socket_path = path }) catch continue;
        defer connection.deinit();
        var result = connection.server.exec(&.{"list-sessions"}) catch continue;
        defer result.deinit();
        if (!result.success()) continue;
        try list.append(a, .{ .name = try a.dupe(u8, entry.name), .options = .{ .socket_path = path } });
    }
}
