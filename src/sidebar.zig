// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const m = @import("model.zig");
const backend = @import("backend.zig");
const tmux = @import("libtmux");
pub const Server = struct { name: []const u8, options: tmux.ServerOptions };
pub const Action = union(enum) { server: usize, display: usize, session: usize, pane: usize, new_session, blink };
pub const Row = struct {
    text: []const u8,
    key: []const u8 = "",
    action: ?Action = null,
    color: u8 = 7,
    active: bool = false,
    heading: bool = false,
    continuation: bool = false,
};
pub fn rows(a: std.mem.Allocator, servers: []const Server, current: usize, snapshot: ?*backend.Snapshot, target: ?backend.Request, label: ?[]const u8, home: ?[]const u8) ![]Row {
    var list: std.ArrayList(Row) = .empty;
    try list.append(a, .{ .text = "servers", .heading = true });
    try list.append(a, .{ .text = "" });
    for (servers, 0..) |server, i| try list.append(a, .{
        .text = server.name,
        .key = try std.fmt.allocPrint(a, "server:{d}", .{i}),
        .action = .{ .server = i },
        .active = i == current,
    });
    try list.appendSlice(a, &.{ .{ .text = "" }, .{ .text = "displays", .heading = true }, .{ .text = "" } });
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
                .text = try std.fmt.allocPrint(a, "{s} : {s}", .{ if (active and label != null) label.? else display_name, name }),
                .key = try std.fmt.allocPrint(a, "display:{s}:{s}:{s}", .{ client.name, client.pid, client.created }),
                .action = .{ .display = i },
                .active = active,
            });
        }
        if (s.clients.len == 0) try list.append(a, .{ .text = "no attached displays", .color = 8 });
    }
    if (target != null) try list.append(a, .{ .text = "  blink", .key = "blink", .action = .blink, .color = 8 });
    try list.appendSlice(a, &.{ .{ .text = "" }, .{ .text = "sessions", .heading = true, .key = "new-session", .action = .new_session }, .{ .text = "" } });
    if (snapshot) |s| {
        for (s.sessions, 0..) |session, i| {
            var active = false;
            if (target) |t| for (s.clients) |client| {
                if (client.same(t.client) and std.mem.eql(u8, client.session, session.id)) active = true;
            };
            try list.append(a, .{ .text = session.name, .key = try std.fmt.allocPrint(a, "session:{s}", .{session.id}), .action = .{ .session = i }, .active = active });
            var has_panes = false;
            for (s.panes, 0..) |pane, pane_index| {
                if (!std.mem.eql(u8, pane.session, session.id)) continue;
                if (!has_panes) try list.append(a, .{ .text = "" });
                has_panes = true;
                const state = m.agentIndicator(pane.state);
                const is_agent = pane.agent.len > 0;
                const pane_active = active and std.mem.eql(u8, pane.id, s.focused_pane);
                const marker = if (pane_active) "▸" else " ";
                const text = if (is_agent)
                    try std.fmt.allocPrint(a, "{s} {s}{s} {s}", .{ marker, if (pane.unread and !std.mem.eql(u8, pane.state, "done")) "✓ " else "", state.symbol, pane.agent })
                else
                    try std.fmt.allocPrint(a, "{s}   {s}", .{ marker, if (pane.command.len > 0) pane.command else "shell" });
                const pane_key = try std.fmt.allocPrint(a, "pane:{s}:{s}", .{ pane.session, pane.id });
                try list.append(a, .{ .text = text, .key = pane_key, .action = .{ .pane = pane_index }, .color = if (is_agent) state.color else 7, .active = pane_active });
                var path = pane.cwd;
                if (home) |h| if (h.len > 0 and std.mem.startsWith(u8, path, h) and (path.len == h.len or path[h.len] == '/')) {
                    path = try std.fmt.allocPrint(a, "~{s}", .{path[h.len..]});
                };
                try list.append(a, .{ .text = try std.fmt.allocPrint(a, "    {s}", .{path}), .color = 8, .key = pane_key, .action = .{ .pane = pane_index }, .continuation = true });
            }
            try list.append(a, .{ .text = "" });
        }
    }
    return list.toOwnedSlice(a);
}

/// Discover sockets only in tmux's conventional per-user directory. Custom
/// socket paths are explicit CLI entries; never traverse arbitrary directories.
pub fn discover(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, environ: std.process.Environ, list: *std.ArrayList(Server)) !void {
    const directory = try std.fmt.allocPrint(a, "{s}/tmux-{d}", .{ env.get("TMUX_TMPDIR") orelse "/tmp", std.c.getuid() });
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
