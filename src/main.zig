// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const vaxis = @import("vaxis");
const tmux = @import("libtmux");
const m = @import("model.zig");
const sidebar = @import("sidebar.zig");
const backend = @import("backend.zig");
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, address: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(message, address);
    }
}.call);
pub const std_options: std.Options = .{ .log_level = .err };
const new_button_col = 11; // "sessions" plus three spaces
const new_button_text = "[new]";
const Event = union(enum) { key_press: vaxis.Key, mouse: vaxis.Mouse, winsize: vaxis.Winsize, snapshot: *backend.Snapshot };
const Editor = struct {
    id: []const u8,
    key: []const u8,
    input: vaxis.widgets.TextInput,
    create: bool = false,
    replace: bool = true,
    pending: bool = false,
    fn init(a: std.mem.Allocator, session: m.Session) !Editor {
        const id = try a.dupe(u8, session.id);
        errdefer a.free(id);
        const key = try std.fmt.allocPrint(a, "session:{s}", .{session.id});
        errdefer a.free(key);
        var input = vaxis.widgets.TextInput.init(a);
        errdefer input.deinit();
        try input.insertSliceAtCursor(session.name);
        return .{ .id = id, .key = key, .input = input };
    }
    fn deinit(self: *Editor, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.key);
        self.input.deinit();
    }
};
const help =
    \\tmm - external tmux session controller
    \\Usage: tmm [-L socket-name | -S socket-path] [--client tty] [--label name]
    \\       tmm [--server name ...] [--server-path path ...]
    \\       tmm [-L socket-name | -S socket-path] --dump
    \\Run beside an ordinary tmux client. Select a display before navigating.
    \\Mouse: hover highlights, click selects, wheel browses without selecting.
    \\Sessions: j/k or arrows to browse, Enter to switch the selected display.
    \\Click a server, display, session, or agent. b blinks the display. q exits.
    \\--dump prints a read-only JSON snapshot without opening the terminal UI.
    \\
;
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    var opts: tmux.ServerOptions = .{};
    var initial_client: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var dump = false;
    var config_arena = std.heap.ArenaAllocator.init(a);
    defer config_arena.deinit();
    const ca = config_arena.allocator();
    var servers: std.ArrayList(sidebar.Server) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buf: [2048]u8 = undefined;
            var out = std.Io.File.stdout().writer(io, &buf);
            try out.interface.writeAll(help);
            try out.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            dump = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            opts.socket_name = args.next() orelse return error.MissingSocketName;
        } else if (std.mem.eql(u8, arg, "-S")) {
            opts.socket_path = args.next() orelse return error.MissingSocketPath;
        } else if (std.mem.eql(u8, arg, "--client")) {
            initial_client = args.next() orelse return error.MissingClient;
        } else if (std.mem.eql(u8, arg, "--server")) {
            const name = args.next() orelse return error.MissingSocketName;
            try servers.append(ca, .{ .name = name, .options = .{ .socket_name = name } });
        } else if (std.mem.eql(u8, arg, "--server-path")) {
            const path = args.next() orelse return error.MissingSocketPath;
            try servers.append(ca, .{ .name = std.fs.path.basename(path), .options = .{ .socket_path = path } });
        } else if (std.mem.eql(u8, arg, "--label")) {
            label = args.next() orelse return error.MissingLabel;
        } else return error.UnknownArgument;
    }
    if (opts.socket_name != null and opts.socket_path != null) return error.ConflictingSocketSelectors;
    if (dump) {
        var snapshot: backend.Snapshot = .{ .arena = .init(a) };
        defer snapshot.arena.deinit();
        var server = try backend.Connection.init(snapshot.arena.allocator(), io, init.minimal.environ, opts);
        defer server.deinit();
        try backend.collect(&server, &snapshot, null);
        var buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &buf);
        try std.json.Stringify.value(.{ .clients = snapshot.clients, .sessions = snapshot.sessions, .panes = snapshot.panes }, .{ .whitespace = .indent_2 }, &out.interface);
        try out.interface.writeAll("\n");
        try out.interface.flush();
        return;
    }
    try servers.insert(ca, 0, .{ .name = opts.socket_name orelse if (opts.socket_path) |path| std.fs.path.basename(path) else "default", .options = opts });
    if (opts.socket_name == null and opts.socket_path == null)
        try sidebar.discover(ca, io, init.environ_map, init.minimal.environ, &servers);
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    var vx = try vaxis.init(io, a, init.environ_map, .{});
    defer vx.deinit(a, tty.writer());
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setMouseMode(tty.writer(), true);
    var shared: backend.Shared = .{};
    var task = try io.concurrent(runWorker, .{ io, a, init.minimal.environ, opts, &shared, &loop });
    defer {
        vx.setMouseMode(tty.writer(), false) catch {};
        shared.stopping.store(true, .release);
        task.cancel(io);
        clearShared(a, &shared);
        drain(a, &loop);
    }
    var snapshot: ?*backend.Snapshot = null;
    defer if (snapshot) |s| s.destroy(a);
    var target: ?backend.Request = null;
    defer if (target) |t| t.deinit(a);
    var current_server: usize = 0;
    var layout_arena = std.heap.ArenaAllocator.init(a);
    defer layout_arena.deinit();
    var rows: []sidebar.Row = &.{};
    var cursor: ?usize = null;
    var mouse_cursor = false;
    var column_width: u16 = 0;
    var pressed: ?[]const u8 = null;
    defer if (pressed) |p| a.free(p);
    var offset: usize = 0;
    var editor: ?Editor = null;
    defer if (editor) |*e| e.deinit(a);
    var error_text: ?[]const u8 = null;
    defer if (error_text) |e| a.free(e);
    var pending_event: ?Event = null;
    defer if (pending_event) |event| switch (event) {
        .snapshot => |s| s.destroy(a),
        else => {},
    };
    while (true) {
        var event = pending_event orelse try loop.nextEvent();
        pending_event = null;
        // Motion is replaceable; clicks, keys, resizes, and snapshots keep order.
        // Bound each batch so a continuous motion stream cannot starve rendering.
        if (event == .mouse and event.mouse.type == .motion) {
            for (0..512) |_| {
                const next = try loop.tryEvent() orelse break;
                if (next == .mouse and next.mouse.type == .motion) event = next else {
                    pending_event = next;
                    break;
                }
            }
            if (mouse_cursor and cursor == mouseHit(rows, offset, event.mouse, vx.window(), column_width)) continue;
        }
        var action: ?sidebar.Action = null;
        var reveal = false;
        const old_key = if (cursor) |c| if (c < rows.len) try a.dupe(u8, rows[c].key) else null else null;
        defer if (old_key) |k| a.free(k);
        switch (event) {
            .winsize => |ws| {
                try vx.resize(a, tty.writer(), ws);
                if (pressed) |p| a.free(p);
                pressed = null;
            },
            .snapshot => |s| {
                if (s.rename_result) |result| if (editor) |*edit| {
                    if (std.mem.eql(u8, result.id, edit.id)) {
                        if (result.success) {
                            edit.deinit(a);
                            editor = null;
                        } else edit.pending = false;
                    }
                };
                if (editor == null or s.failure != null) {
                    if (error_text) |e| a.free(e);
                    error_text = if (s.failure) |e| try a.dupe(u8, e) else null;
                }
                if (!s.valid) s.destroy(a) else {
                    if (snapshot) |old| old.destroy(a);
                    snapshot = s;
                    if (initial_client) |name| {
                        for (s.clients) |client| if (std.mem.eql(u8, client.name, name)) {
                            target = try backend.Request.copy(a, client, null);
                            shared.send(io, a, try backend.Request.copy(a, client, null));
                            break;
                        };
                        initial_client = null;
                        if (target == null) {
                            if (error_text) |e| a.free(e);
                            error_text = try a.dupe(u8, "Requested display is not attached");
                        }
                    }
                }
            },
            .mouse => |mouse| {
                mouse_cursor = true;
                if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
                    if (pressed) |p| a.free(p);
                    pressed = null;
                    if (mouse.type == .press) {
                        if (mouse.button == .wheel_up) offset -|= 3 else offset = @min(offset + 3, rows.len -| 1);
                    }
                } else {
                    const index = mouseHit(rows, offset, mouse, vx.window(), column_width);
                    if (mouse.type == .motion) {
                        cursor = index;
                    }
                    if (mouse.type == .press and mouse.button == .left) {
                        if (pressed) |p| a.free(p);
                        pressed = if (index) |i| try a.dupe(u8, rows[i].key) else null;
                        cursor = index;
                    }
                    if (mouse.type == .release) {
                        if (mouse.button == .left) if (index) |i| if (pressed) |p| {
                            if (std.mem.eql(u8, p, rows[i].key)) action = rows[i].action;
                        };
                        if (pressed) |p| a.free(p);
                        pressed = null;
                    }
                }
            },
            .key_press => |key| key_event: {
                mouse_cursor = false;
                if (pressed) |p| a.free(p);
                pressed = null;
                if (editor) |*edit| {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                        if (!edit.pending) {
                            edit.deinit(a);
                            editor = null;
                        }
                    } else if (!edit.pending) {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            const name = try edit.input.toOwnedContents(a);
                            defer a.free(name);
                            if (!m.validSessionName(name)) {
                                if (error_text) |e| a.free(e);
                                error_text = try a.dupe(u8, "Use a nonempty name without dots, colons, or control characters");
                            } else {
                                try shared.renameSession(io, a, edit.id, name, edit.create, if (edit.create) if (target) |t| t.client else null else null);
                                edit.pending = true;
                            }
                        } else {
                            if (edit.replace) {
                                if ((key.text != null and !key.mods.ctrl and !key.mods.alt) or key.matches(vaxis.Key.backspace, .{}))
                                    edit.input.clearRetainingCapacity();
                                edit.replace = false;
                            }
                            try edit.input.update(.{ .key_press = key });
                        }
                    }
                    break :key_event;
                }
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('b', .{})) {
                    if (cursor) |c| {
                        if (rows[c].action) |selected| switch (selected) {
                            .display => |i| if (snapshot) |s| {
                                try shared.blinkDisplay(io, a, s.clients[i]);
                            },
                            else => if (target) |t| {
                                try shared.blinkDisplay(io, a, t.client);
                            },
                        };
                    } else if (target) |t| try shared.blinkDisplay(io, a, t.client);
                }
                const down = key.matches('j', .{}) or key.matches(vaxis.Key.down, .{});
                const up = key.matches('k', .{}) or key.matches(vaxis.Key.up, .{});
                if ((down or up) and rows.len > 0) {
                    var i = cursor orelse if (down) rows.len - 1 else 0;
                    for (0..rows.len) |_| {
                        i = if (down) (i + 1) % rows.len else (i + rows.len - 1) % rows.len;
                        if (rows[i].action != null and !rows[i].continuation) {
                            cursor = i;
                            break;
                        }
                    }
                    reveal = true;
                }
                if (key.matches(vaxis.Key.enter, .{})) if (cursor) |c| {
                    action = rows[c].action;
                };
            },
        }
        // Preserve the highlighted object across topology changes, not its row index.
        const cursor_key = if (event == .snapshot) old_key else if (cursor) |c| if (c < rows.len) rows[c].key else null else null;
        const keep_key = if (cursor_key) |k| try a.dupe(u8, k) else null;
        defer if (keep_key) |k| a.free(k);
        if (action != null and editor != null) {
            // Leaving the field cancels an unsaved edit; submitted requests finish first.
            if (editor.?.pending) action = null else {
                editor.?.deinit(a);
                editor = null;
            }
        }
        if (action) |selected| switch (selected) {
            .server => |i| if (i != current_server) {
                shared.stopping.store(true, .release);
                task.cancel(io);
                clearShared(a, &shared);
                drain(a, &loop);
                if (snapshot) |s| s.destroy(a);
                snapshot = null;
                if (target) |t| t.deinit(a);
                target = null;
                if (error_text) |e| a.free(e);
                error_text = null;
                current_server = i;
                opts = servers.items[i].options;
                shared.stopping.store(false, .release);
                task = try io.concurrent(runWorker, .{ io, a, init.minimal.environ, opts, &shared, &loop });
            },
            .display => |i| if (snapshot) |s| {
                const next = try backend.Request.copy(a, s.clients[i], null);
                if (target) |t| t.deinit(a);
                target = next;
                shared.send(io, a, try backend.Request.copy(a, s.clients[i], null));
            },
            .session => |i| if (snapshot) |s| {
                if (event == .mouse) {
                    editor = try Editor.init(a, s.sessions[i]);
                    if (error_text) |e| a.free(e);
                    error_text = null;
                } else if (target) |t| shared.send(io, a, try backend.Request.copy(a, t.client, s.sessions[i].id)) else {
                    if (error_text) |e| a.free(e);
                    error_text = try a.dupe(u8, "Select a display first");
                }
            },
            .pane => |i| if (snapshot) |s| {
                if (target) |t| {
                    var request = try backend.Request.copy(a, t.client, s.panes[i].session);
                    errdefer request.deinit(a);
                    request.pane = try a.dupe(u8, s.panes[i].id);
                    request.window = try a.dupe(u8, s.panes[i].window);
                    request.completion = s.panes[i].completion;
                    request.run_identity = try a.dupe(u8, s.panes[i].run_identity);
                    shared.send(io, a, request);
                } else {
                    if (error_text) |e| a.free(e);
                    error_text = try a.dupe(u8, "Select a display first");
                }
            },
            .new_session => if (target == null) {
                if (error_text) |e| a.free(e);
                error_text = try a.dupe(u8, "Select a display first");
            } else {
                editor = try Editor.init(a, .{ .id = "", .name = "", .path = "" });
                editor.?.create = true;
                if (error_text) |e| a.free(e);
                error_text = null;
            },
            .blink => if (target) |t| {
                try shared.blinkDisplay(io, a, t.client);
            },
        };
        _ = layout_arena.reset(.retain_capacity);
        const fa = layout_arena.allocator();
        rows = try sidebar.rows(fa, servers.items, current_server, snapshot, target, label, init.environ_map.get("HOME"));
        if (editor) |edit| if (edit.create) {
            for (rows, 0..) |row, i| if (row.action != null and row.action.? == .new_session and i + 1 < rows.len) {
                rows[i + 1].key = edit.key;
                break;
            };
        };
        cursor = null;
        if (keep_key) |k| for (rows, 0..) |row, i| if (row.action != null and std.mem.eql(u8, row.key, k)) {
            cursor = i;
            break;
        };
        const win = vx.window();
        column_width = @min(win.width, new_button_col + new_button_text.len);
        for (rows) |row| {
            const safe = try m.display(fa, row.text);
            column_width = @min(win.width, @max(column_width, win.gwidth(safe) +| 1));
        }
        const visible: usize = win.height -| 4;
        offset = @min(offset, rows.len -| visible);
        if (reveal) if (cursor) |c| {
            if (c < offset) offset = c;
            if (c >= offset + visible) offset = c + 1 -| visible;
        };
        win.clear();
        win.hideCursor();
        draw(win, fa, 0, "tmm : tmux micro manager", .{ .bold = true, .fg = .{ .index = 6 } });
        for (rows[offset..], 0..) |row, i| {
            if (i >= visible) break;
            const highlighted = cursor != null and row.action != null and std.mem.eql(u8, rows[cursor.?].key, row.key);
            if (editor) |*edit| if (std.mem.eql(u8, edit.key, row.key)) {
                draw(win, fa, i + 2, "[", .{ .fg = .{ .index = 14 } });
                if (win.width >= 3) {
                    const field = win.child(.{ .x_off = 1, .y_off = @intCast(i + 2), .width = win.width - 2, .height = 1 });
                    edit.input.drawWithStyle(field, .{ .fg = .{ .index = 14 }, .ul_style = .single });
                    win.writeCell(win.width - 1, @intCast(i + 2), .{ .char = .{ .grapheme = "]" }, .style = .{ .fg = .{ .index = 14 } } });
                }
                continue;
            };
            if (row.action != null and row.action.? == .new_session) {
                const heading_win = win.child(.{ .width = @min(win.width, new_button_col) });
                draw(heading_win, fa, i + 2, row.text, .{ .bold = true, .ul_style = .single });
                const button = win.child(.{ .x_off = @min(win.width, new_button_col), .width = @min(win.width -| new_button_col, new_button_text.len) });
                draw(button, fa, i + 2, new_button_text, .{
                    .bg = if (highlighted) .{ .rgb = .{ 38, 43, 49 } } else .default,
                    .fg = .{ .index = if (highlighted) 7 else 8 },
                    .bold = highlighted,
                });
                continue;
            }
            const selected = row.active or (row.continuation and offset + i > 0 and rows[offset + i - 1].active);
            const background: vaxis.Cell.Color = if (highlighted)
                .{ .rgb = .{ 38, 43, 49 } }
            else if (selected)
                .{ .rgb = .{ 27, 35, 43 } }
            else
                .default;
            if (row.action != null) {
                const rectangle = win.child(.{ .y_off = @intCast(i + 2), .width = column_width, .height = 1 });
                rectangle.fill(.{ .style = .{ .bg = background } });
            }
            draw(win, fa, i + 2, row.text, .{
                .bg = background,
                .fg = .{ .index = if (row.active or (highlighted and !mouse_cursor)) 14 else if (highlighted) (if (row.color < 8) row.color + 8 else 7) else row.color },
                .bold = (highlighted and !mouse_cursor) or row.active or row.heading,
                .ul_style = if (row.heading) .single else .off,
            });
        }
        if (win.height >= 2) draw(win, fa, win.height - 2, error_text orelse "", .{ .fg = .{ .index = 1 } });
        if (win.height >= 1) draw(win, fa, win.height - 1, if (editor) |edit| if (edit.pending) "saving..." else "Enter save  Esc cancel" else "j/k move  q quit", .{ .fg = .{ .index = 8 } });
        try vx.render(tty.writer());
    }
}
fn mouseHit(rows: []const sidebar.Row, offset: usize, mouse: vaxis.Mouse, win: vaxis.Window, column_width: u16) ?usize {
    if (mouse.row < 2 or mouse.row >= @as(i32, win.height) - 2 or mouse.col < 0 or mouse.col >= @min(win.width, column_width)) return null;
    const i = offset + @as(usize, @intCast(mouse.row - 2));
    if (i >= rows.len or rows[i].action == null) return null;
    if (rows[i].action.? == .new_session and (mouse.col < new_button_col or mouse.col >= new_button_col + new_button_text.len)) return null;
    return if (rows[i].continuation and i > 0) i - 1 else i;
}
fn clearShared(a: std.mem.Allocator, shared: *backend.Shared) void {
    if (shared.request) |r| r.deinit(a);
    if (shared.blink) |r| r.deinit(a);
    if (shared.rename) |r| r.deinit(a);
    shared.request = null;
    shared.blink = null;
    shared.rename = null;
}
fn drain(a: std.mem.Allocator, loop: *vaxis.Loop(Event)) void {
    while (loop.tryEvent() catch null) |event| switch (event) {
        .snapshot => |s| s.destroy(a),
        else => {},
    };
}
fn runWorker(io: std.Io, a: std.mem.Allocator, environ: std.process.Environ, opts: tmux.ServerOptions, shared: *backend.Shared, loop: *vaxis.Loop(Event)) void {
    backend.worker(io, a, environ, opts, shared, loop);
}
fn draw(win: vaxis.Window, a: std.mem.Allocator, row: usize, text: []const u8, style: vaxis.Cell.Style) void {
    if (row >= win.height) return;
    const safe = m.display(a, text) catch return;
    _ = win.printSegment(.{ .text = safe, .style = style }, .{ .row_offset = @intCast(row), .wrap = .none });
}
