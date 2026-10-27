// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const vaxis = @import("vaxis");
const tmux = @import("libtmux");
const m = @import("model.zig");
const sidebar = @import("sidebar.zig");
const backend = @import("backend.zig");
const aurora = @import("aurora.zig");
const banner = @import("banner.zig");
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, address: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(message, address);
    }
}.call);
pub const std_options: std.Options = .{ .log_level = .err };
const new_button_col = 11; // "sessions" plus three spaces
const new_button_text = "[new]";
const Event = union(enum) { key_press: vaxis.Key, mouse: vaxis.Mouse, focus_out, color_report: vaxis.Cell.Color.Report, winsize: vaxis.Winsize, snapshot: *backend.Snapshot };
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
    // One lettering for the whole run, so it does not change under the person.
    const lettering = banner.choose(init.environ_map.get("TMM_BANNER"), roll: {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        break :roll std.mem.readInt(u64, &bytes, .little);
    });
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
        } else {
            // Said in words and exited, rather than returned as an error:
            // a return trace under a typo reads as a crash in tmm. The modes
            // that went away get a pointer to where they went, since habit
            // will keep typing them for a while.
            var buf: [512]u8 = undefined;
            var out = std.Io.File.stderr().writer(io, &buf);
            const removed = for ([_][]const u8{ "--panes", "--shell", "--split", "--session", "--focus-key" }) |flag| {
                if (std.mem.eql(u8, arg, flag)) break true;
            } else false;
            if (removed) {
                try out.interface.print(
                    "tmm: {s} was removed; tmm is a sidebar controller now.\n" ++
                        "The terminal region and compositor are kept at the tag compositor-final.\n",
                    .{arg},
                );
            } else try out.interface.print("tmm: unknown argument {s}; see tmm --help\n", .{arg});
            try out.interface.flush();
            std.process.exit(2);
        }
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
    // The background the selected session's card fades into.
    try vx.queryColor(tty.writer(), .bg);
    var shared: backend.Shared = .{};
    var task = try io.concurrent(runWorker, .{ io, a, init.minimal.environ, opts, &shared, &loop });
    var control_task = try io.concurrent(backend.controlWorker, .{ io, a, opts, &shared });
    var heartbeat_task = try io.concurrent(backend.heartbeatWorker, .{ io, &shared });
    defer {
        vx.setMouseMode(tty.writer(), false) catch {};
        shared.stopping.store(true, .release);
        // Wake the collector before cancelling so it exits its semaphore wait
        // on its own terms rather than mid-collect.
        shared.wake.post(io);
        heartbeat_task.cancel(io);
        control_task.cancel(io);
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
    // The sidebar's own box, kept across iterations because mouse events are
    // resolved against the previous frame's geometry.
    var sidebar_width: u16 = vx.window().width -| gutter;
    var sidebar_height: u16 = vx.window().height;
    var pressed: ?[]const u8 = null;
    defer if (pressed) |p| a.free(p);
    var offset: usize = 0;
    // Sessions folded to their name, by session id. Owned keys; a session
    // that has gone simply never matches again.
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = folded.keyIterator();
        while (keys.next()) |k| a.free(k.*);
        folded.deinit(a);
    }
    var editor: ?Editor = null;
    defer if (editor) |*e| e.deinit(a);
    var error_text: ?[]const u8 = null;
    defer if (error_text) |e| a.free(e);
    // A frame budget, so a burst of events costs one draw rather than one
    // each, and a keypress arriving during the wait is handled before the
    // render it would otherwise sit behind. movy paces a game loop to an
    // absolute deadline and sleeps the remainder for the same reason.
    // `TMM_FRAME_BUDGET_MS=0` turns it off, for measuring what it buys.
    const frame_budget_ns: u64 = budget: {
        const text = init.environ_map.get("TMM_FRAME_BUDGET_MS") orelse break :budget 16 * std.time.ns_per_ms;
        const ms = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch break :budget 16 * std.time.ns_per_ms;
        break :budget ms * std.time.ns_per_ms;
    };
    var last_draw: std.Io.Timestamp = .now(io, .awake);
    var pending_event: ?Event = null;
    defer if (pending_event) |event| switch (event) {
        .snapshot => |s| s.destroy(a),
        else => {},
    };
    while (true) {
        var event = intoBody(pending_event orelse try loop.nextEvent());
        pending_event = null;
        // Motion is replaceable; clicks, keys, resizes, and snapshots keep order.
        // Bound each batch so a continuous motion stream cannot starve rendering.
        if (event == .mouse and event.mouse.type == .motion) {
            for (0..512) |_| {
                const next = try loop.tryEvent() orelse break;
                if (next == .mouse and next.mouse.type == .motion) event = intoBody(next) else {
                    pending_event = next;
                    break;
                }
            }
            if (mouse_cursor and cursor == mouseHit(rows, offset, event.mouse, sidebar_width, sidebar_height, column_width)) continue;
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
                    // With one display and none chosen yet there is nothing
                    // to choose: select it, at launch or when it is the first
                    // to attach. A chosen display that detached stays chosen,
                    // so the next command reports it gone rather than acting
                    // on a display nobody picked.
                    if (target == null and s.clients.len == 1) {
                        target = try backend.Request.copy(a, s.clients[0], null);
                        shared.send(io, a, try backend.Request.copy(a, s.clients[0], null));
                    }
                }
            },
            // The pane hears nothing when the mouse merely leaves it, but
            // losing focus is the next best sign the pointer went elsewhere.
            .focus_out => if (mouse_cursor) {
                cursor = null;
            },
            .color_report => |report| if (report.kind == .bg) {
                terminal_bg = report.value;
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
                    const index = mouseHit(rows, offset, mouse, sidebar_width, sidebar_height, column_width);
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
                            if (action) |chosen| if (chosen == .session and mouse.col < sidebar.fold_width) {
                                action = .{ .fold = chosen.session };
                            };
                            // The mark at the end of the selected display.
                            if (action) |chosen| if (chosen == .display and rows[i].active and
                                std.mem.endsWith(u8, rows[i].text, sidebar.blink_mark) and
                                mouse.col + 1 >= vx.window().gwidth(rows[i].text))
                            {
                                action = .blink;
                            };
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
                        if (rows[i].action != null) {
                            cursor = i;
                            break;
                        }
                    }
                    reveal = true;
                }
                if (key.matches(vaxis.Key.enter, .{})) if (cursor) |c| {
                    action = rows[c].action;
                };
                if (key.matches(vaxis.Key.space, .{})) if (cursor) |c| if (rows[c].action) |chosen| if (chosen == .session) {
                    action = .{ .fold = chosen.session };
                };
            },
        }
        // Preserve the highlighted object across topology changes, not its row index.
        const cursor_key = if (event == .snapshot) old_key else if (event == .focus_out) null else if (cursor) |c| if (c < rows.len) rows[c].key else null else null;
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
                // Wake first: the collector parks on shared.wake, and the old
                // control task must go before a new one targets another server.
                shared.wake.post(io);
                heartbeat_task.cancel(io);
                control_task.cancel(io);
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
                control_task = try io.concurrent(backend.controlWorker, .{ io, a, opts, &shared });
                heartbeat_task = try io.concurrent(backend.heartbeatWorker, .{ io, &shared });
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
            .fold => |i| if (snapshot) |s| {
                if (folded.fetchRemove(s.sessions[i].id)) |entry| a.free(entry.key) else {
                    const id = try a.dupe(u8, s.sessions[i].id);
                    errdefer a.free(id);
                    try folded.put(a, id, {});
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
        rows = try sidebar.rows(fa, servers.items, current_server, snapshot, target, label, init.environ_map.get("HOME"), &folded);
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
        const win = vx.window().child(.{ .x_off = gutter });
        // The widest row decides the clickable column, so a click to the right
        // of every row's text selects nothing rather than the row beside it.
        var natural: u16 = new_button_col + new_button_text.len;
        for (rows) |row| {
            const safe = try m.display(fa, row.text);
            var width = win.gwidth(safe) +| 1;
            if (row.detail.len > 0) width +|= win.gwidth(try m.display(fa, row.detail)) +| 1;
            natural = @max(natural, width);
        }
        sidebar_width = win.width;
        sidebar_height = win.height;
        column_width = @min(win.width, natural);
        // The banner, then a blank row, then the list; the plain title when
        // the banner is wider than the window.
        const title = if (bannerWidth(win, lettering) <= win.width) lettering else banner.plain;
        top = @intCast(title.lines.len + 1);
        const visible: usize = win.height -| (top + 2);
        offset = @min(offset, rows.len -| visible);
        if (reveal) if (cursor) |c| {
            if (c < offset) offset = c;
            if (c >= offset + visible) offset = c + 1 -| visible;
        };
        vx.window().clear();
        win.hideCursor();
        field_rows = @intCast(@min(rows.len -| offset, visible) + top);
        field_cols = column_width;
        drawBanner(win, fa, title);
        for (rows[offset..], 0..) |row, i| {
            if (i >= visible) break;
            const highlighted = cursor != null and row.action != null and std.mem.eql(u8, rows[cursor.?].key, row.key);
            if (editor) |*edit| if (std.mem.eql(u8, edit.key, row.key)) {
                draw(win, fa, i + top, "[", .{ .fg = .{ .index = 14 } });
                if (win.width >= 3) {
                    const field = win.child(.{ .x_off = 1, .y_off = @intCast(i + top), .width = win.width - 2, .height = 1 });
                    edit.input.drawWithStyle(field, .{ .fg = .{ .index = 14 }, .ul_style = .single });
                    win.writeCell(win.width - 1, @intCast(i + top), .{ .char = .{ .grapheme = "]" }, .style = .{ .fg = .{ .index = 14 } } });
                }
                continue;
            };
            if (row.action != null and row.action.? == .new_session) {
                const heading_win = win.child(.{ .width = @min(win.width, new_button_col) });
                draw(heading_win, fa, i + top, row.text, .{ .bold = true });
                tint(win, i + top, 0, new_button_col, .full);
                const button = win.child(.{ .x_off = @min(win.width, new_button_col), .width = @min(win.width -| new_button_col, new_button_text.len) });
                draw(button, fa, i + top, new_button_text, .{
                    .fg = .{ .index = if (highlighted) 7 else 8 },
                    .bold = highlighted,
                });
                continue;
            }
            const background: vaxis.Cell.Color = .default;
            // A folded session with a finished result is green whatever
            // else it is: that is the one thing the fold has to show.
            const color: u8 = if (row.done) 2 else if (row.active) 14 else row.color;
            const text_style: vaxis.Cell.Style = .{
                .bg = background,
                .fg = .{ .index = color },
                .bold = row.active or row.heading or row.done,
            };
            draw(win, fa, i + top, row.text, text_style);
            if (row.detail.len > 0) {
                const after = win.gwidth(m.display(fa, row.text) catch row.text) +| 1;
                if (after < win.width) {
                    const fits = tail(win, fa, m.display(fa, row.detail) catch row.detail, win.width - after);
                    draw(win.child(.{ .x_off = after }), fa, i + top, fits, .{ .bg = background, .fg = .{ .index = 8 } });
                    tint(win, i + top, after, win.width, .dim);
                }
            }
            // Names that are not status take their colour from the field:
            // a session dimmed, and whatever is current lifted toward
            // white. Status colours keep their meaning and are left alone.
            const is_session = row.action != null and row.action.? == .session;
            if (row.heading) {
                tint(win, i + top, 0, win.width, .full);
            } else if (is_session and !row.done) {
                // Session names in the cool end of the field, so they stand
                // apart from the purple directories beside them.
                const end = win.gwidth(m.display(fa, row.text) catch row.text);
                tint(win, i + top, 0, end, if (row.active) .cool_lift else .cool);
            } else if (isEntry(row)) {
                // Servers and displays in green, well away from the pink of
                // the headings above them; the blink mark in gold.
                const end = win.gwidth(m.display(fa, row.text) catch row.text);
                paint(win, i + top, 0, end, entry_rgb);
                if (std.mem.endsWith(u8, row.text, sidebar.blink_mark)) paint(win, i + top, end -| 1, end, blink_rgb);
                // The arrow is the entry's whole selection mark, in the
                // bar's colour; the pointer's entry gets it dimmed.
                if (row.active) {
                    paint(win, i + top, 0, 1, bar_rgb);
                } else if (highlighted) {
                    win.writeCell(0, @intCast(i + top), .{ .char = .{ .grapheme = sidebar.entry_mark, .width = 1 }, .style = .{ .fg = .{ .rgb = hover_rgb } } });
                }
            } else if (row.active and row.color == 7 and row.name_rgb == null) {
                tint(win, i + top, 0, win.width, .lift);
            }
            if (row.symbol.len > 0) paintSymbols(win, i + top, row.symbol, row.symbol_color);
            if (row.name_rgb) |rgb| if (std.mem.indexOf(u8, row.text, row.name)) |at| {
                const from = win.gwidth(m.display(fa, row.text[0..at]) catch row.text[0..at]);
                paint(win, i + top, from, from + win.gwidth(m.display(fa, row.name) catch row.name), rgb);
            };
        }
        // Bars in the gutter, card edges beside a whole group through the
        // blank row that closes it, a little wider at the row itself. What
        // is selected keeps a bright one; the pointer or cursor gets a dim
        // one. The lines themselves are never recoloured.
        const bars = try fa.alloc(Bar, rows.len);
        @memset(bars, .none);
        // Servers and displays carry their arrow instead.
        for (rows, 0..) |row, r| if (row.action != null and row.active and !isEntry(row)) {
            const group = groupAround(rows, r);
            for (bars[group.first .. group.last + 1]) |*b| if (b.* == .none) {
                b.* = .selected;
            };
        };
        // Wide at the last selected row of a group: a session's current
        // pane rather than the session above it.
        for (rows, 0..) |row, r| if (row.action != null and row.active and !isEntry(row)) {
            const later = for (rows[r + 1 .. groupAround(rows, r).last + 1]) |next| {
                if (next.action != null and next.active) break true;
            } else false;
            if (!later) bars[r] = .selected_wide;
        };
        if (cursor) |c| if (c < rows.len and !isEntry(rows[c])) {
            const group = groupAround(rows, c);
            for (bars[group.first .. group.last + 1]) |*b| if (b.* == .none) {
                b.* = .hover;
            };
            if (bars[c] != .selected_wide) bars[c] = .hover_wide;
        };
        // The selected session sits on a faint card the height of its bar,
        // from its name through the blank row after it, fading out to the
        // right, under the bars.
        for (rows, 0..) |row, r| if (row.active and row.action != null and row.action.? == .session) {
            const group = groupAround(rows, r);
            for (group.first..group.last + 1) |card| {
                if (card < offset or card - offset >= visible) continue;
                shade(vx.window(), card - offset + top);
            }
        };
        for (bars, 0..) |b, r| {
            if (b == .none or r < offset or r - offset >= visible) continue;
            drawBar(vx.window(), r - offset + top, b);
        }
        if (win.height >= 2) draw(win, fa, win.height - 2, error_text orelse "", .{ .fg = .{ .index = 1 } });
        if (win.height >= 1) draw(win, fa, win.height - 1, if (editor) |edit|
            if (edit.pending) "saving..." else "Enter save  Esc cancel"
        else
            "j/k move  space fold  q quit", .{ .fg = .{ .index = 8 } });

        // Wait out the rest of the frame budget, and hand over the moment
        // input arrives: a frame rendered late is invisible, and the key
        // that interrupted it is now in front of the render rather than
        // behind it. Only the render waits; the layout above is this
        // frame's, and the hit-test extents it set must not be skipped.
        while (frame_budget_ns > 0) {
            const now: std.Io.Timestamp = .now(io, .awake);
            const since: u64 = @intCast(@max(0, last_draw.durationTo(now).nanoseconds));
            if (since >= frame_budget_ns) break;
            if (try loop.tryEvent()) |next| {
                pending_event = next;
                break;
            }
            io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_us }, .awake) catch break;
        }
        if (pending_event != null) continue;

        try vx.render(tty.writer());
        last_draw = .now(io, .awake);
    }
}

fn mouseHit(rows: []const sidebar.Row, offset: usize, mouse: vaxis.Mouse, width: u16, height: u16, column_width: u16) ?usize {
    if (mouse.row < top or mouse.row >= @as(i32, height) - 2 or mouse.col < -@as(i16, @intCast(gutter)) or mouse.col >= @min(width, column_width)) return null;
    const i = offset + @as(usize, @intCast(mouse.row - @as(i16, @intCast(top))));
    if (i >= rows.len or rows[i].action == null) return null;
    if (rows[i].action.? == .new_session and (mouse.col < new_button_col or mouse.col >= new_button_col + new_button_text.len)) return null;
    return i;
}
/// Drop everything `Shared` owns. Both callers cancel the collector and the
/// control worker first, so nothing is queued behind this and the mutex is
/// not needed; it is also why the queues can be freed rather than handed on.
///
/// The two queues are the point. `controlWorker` fills them from the moment
/// it attaches, and only the collector's next pass empties them, so quitting
/// before that pass leaked every queued line and pane id along with the list
/// that held them -- which `tmm` then `q` does reliably on a server with any
/// output in it. A server switch takes the same path, and there it leaked
/// once per switch rather than once per run.
fn clearShared(a: std.mem.Allocator, shared: *backend.Shared) void {
    if (shared.request) |r| r.deinit(a);
    if (shared.blink) |r| r.deinit(a);
    if (shared.rename) |r| r.deinit(a);
    shared.request = null;
    shared.blink = null;
    shared.rename = null;
    for (shared.events.items) |line| a.free(line);
    shared.events.deinit(a);
    shared.events = .empty;
    shared.events_dropped = false;
    for (shared.output_panes.items) |pane| a.free(pane);
    shared.output_panes.deinit(a);
    shared.output_panes = .empty;
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
/// The row the list starts on: below the banner and one blank row. Set each
/// frame; mouse hits are resolved against the last frame's value.
var top: u16 = 2;

fn bannerWidth(win: vaxis.Window, title: banner.Banner) u16 {
    var widest: u16 = 0;
    for (title.lines) |line| widest = @max(widest, win.gwidth(line));
    return widest;
}

/// The banner in the full aurora field, stretched over the banner alone so
/// even a small one sweeps every corner, and the subtitle to its right,
/// faded, when there is room.
fn drawBanner(win: vaxis.Window, a: std.mem.Allocator, title: banner.Banner) void {
    const width = bannerWidth(win, title);
    const height: u16 = @intCast(title.lines.len);
    for (title.lines, 0..) |line, y| {
        draw(win, a, y, line, .{ .bold = true });
        var x: u16 = 0;
        while (x < @min(width, win.width)) : (x += 1) {
            var cell = win.readCell(x, @intCast(y)) orelse continue;
            cell.style.fg = .{ .rgb = aurora.at(width, height, x, @intCast(y)) };
            win.writeCell(x, @intCast(y), cell);
        }
    }
    if (title.lines.len == 1) return;
    // Two lines starting in the same column, so tmux's t sits over the µ,
    // centred on the banner and a row low when it cannot be exact.
    const subtitle = [_][]const u8{ "tmux", "µmanager" };
    const span: u16 = 8;
    const at = width + 2;
    if (at + span > win.width) return;
    const first: u16 = (height -| 1) / 2;
    for (subtitle, 0..) |line, i| {
        const y: u16 = first + @as(u16, @intCast(i));
        draw(win.child(.{ .x_off = at }), a, y, line, .{});
        var x: u16 = at;
        while (x < at + span) : (x += 1) {
            var cell = win.readCell(x, y) orelse continue;
            cell.style.fg = .{ .rgb = aurora.dim(aurora.at(at + span, height, x, y)) };
            win.writeCell(x, y, cell);
        }
    }
}

/// `text` cut to `width` columns from the left, with `…` where the cut was:
/// the end of a path is the part that says which directory it is.
fn tail(win: vaxis.Window, a: std.mem.Allocator, text: []const u8, width: u16) []const u8 {
    if (win.gwidth(text) <= width) return text;
    if (width < 2) return "";
    var start: usize = 0;
    while (start < text.len) {
        start += std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        if (win.gwidth(text[start..]) + 1 <= width) break;
    }
    return std.fmt.allocPrint(a, "…{s}", .{text[start..]}) catch text[start..];
}

/// Colour cells `from` to `to` of `row` one flat colour.
fn paint(win: vaxis.Window, row: usize, from: u16, to: u16, rgb: [3]u8) void {
    if (row >= win.height) return;
    var x = from;
    while (x < @min(to, win.width)) : (x += 1) {
        var cell = win.readCell(x, @intCast(row)) orelse continue;
        cell.style.fg = .{ .rgb = rgb };
        win.writeCell(x, @intCast(row), cell);
    }
}

/// How far down the field runs: over the list as drawn rather than the whole
/// window, so a short list in a tall window still sweeps from pink to teal
/// instead of staying at the pink end. Set each frame before any tint. A
/// cell past the end takes the far edge's colour.
var field_rows: u16 = 0;
/// Likewise across: the widest row, not the window, which is usually wider
/// than anything in it.
var field_cols: u16 = 0;
fn fieldHeight(win: vaxis.Window) u16 {
    return if (field_rows == 0) win.height else @min(field_rows, win.height);
}
fn fieldWidth(win: vaxis.Window) u16 {
    return if (field_cols == 0) win.width else @min(field_cols, win.width);
}
/// Recolour the text already drawn in `row` from the aurora field. Blank
/// cells are recoloured too, which is harmless: they draw nothing.
fn tint(win: vaxis.Window, row: usize, from: u16, to: u16, how: enum { full, dim, lift, cool, cool_lift }) void {
    const down = fieldHeight(win);
    if (row >= win.height) return;
    var x = from;
    while (x < @min(to, win.width)) : (x += 1) {
        var cell = win.readCell(x, @intCast(row)) orelse continue;
        const field = aurora.at(fieldWidth(win), down, @min(x, fieldWidth(win) -| 1), @min(@as(u16, @intCast(row)), down -| 1));
        cell.style.fg = .{ .rgb = switch (how) {
            .full => field,
            .dim => aurora.dim(field),
            .lift => aurora.lift(field),
            .cool => aurora.cool(down, @min(@as(u16, @intCast(row)), down -| 1)),
            .cool_lift => aurora.lift(aurora.cool(down, @min(@as(u16, @intCast(row)), down -| 1))),
        } };
        win.writeCell(x, @intCast(row), cell);
    }
}
/// Colour a pane row's status glyphs on their own: its state symbol, and the
/// check an unread completion adds before it. They sit in the first few
/// cells, ahead of the name.
fn paintSymbols(win: vaxis.Window, row: usize, symbol: []const u8, color: u8) void {
    if (row >= win.height) return;
    var x: u16 = 0;
    while (x < @min(8, win.width)) : (x += 1) {
        var cell = win.readCell(x, @intCast(row)) orelse continue;
        const glyph = cell.char.grapheme;
        if (std.mem.eql(u8, glyph, "✓")) cell.style.fg = .{ .index = 2 } else if (std.mem.eql(u8, glyph, symbol)) cell.style.fg = .{ .index = color } else continue;
        win.writeCell(x, @intCast(row), cell);
    }
}
/// Lay a background of the field, `percent` strong, under `row`.
/// Columns kept clear on the left for the hover bar, which marks the row
/// the pointer or cursor is on the way a card's edge does.
const gutter: u16 = 1;
/// The selection's bar, a green-cyan that no heading or name is drawn in,
/// and the hover's, the same green greyed and dimmed.
const bar_rgb: aurora.RGB = .{ 72, 214, 176 };
const hover_rgb: aurora.RGB = .{ 58, 96, 90 };
/// Behind the selected session: a dark blue-teal barely off the background.
const card_rgb: aurora.RGB = .{ 20, 28, 33 };
/// Columns at the right left as the plain background.
const card_margin = 0;
/// The terminal's own background, as it reports it; until it does, a near
/// black, so the card fades out against a dark theme without an edge.
var terminal_bg: aurora.RGB = .{ 20, 21, 21 };
/// The card behind `row`, fading from its colour at the left toward the
/// terminal's background at the right edge. Cells in the margin past the
/// fade are left alone, so they are the background exactly even when the
/// terminal never said what it is.
fn shade(win: vaxis.Window, row: usize) void {
    if (row >= win.height) return;
    const start = card_rgb;
    const span = @max(win.width -| card_margin, 1);
    var x: u16 = 0;
    while (x < span) : (x += 1) {
        var cell = win.readCell(x, @intCast(row)) orelse continue;
        // A cleared cell is drawn by erasing, which would drop the shade.
        cell.default = false;
        // A cubic ease-in: the colour holds through most of the row and
        // drops late. It reaches four fifths of the way to the background
        // at the edge, which against a card this close to the background
        // is a step or two, too little to read as an edge.
        const t: u64 = @as(u64, x) * 1000 / span;
        const eased: u32 = @intCast(t * t * t / 1_250_000);
        cell.style.bg = .{ .rgb = aurora.mix(start, terminal_bg, eased, 1000) };
        win.writeCell(x, @intCast(row), cell);
    }
}
/// Server and display names.
const entry_rgb: aurora.RGB = .{ 150, 206, 128 };
/// The blink mark, warm so it reads as something to press.
const blink_rgb: aurora.RGB = .{ 232, 198, 104 };
/// A server or display row.
fn isEntry(row: sidebar.Row) bool {
    const action = row.action orelse return false;
    return action == .server or action == .display;
}
const Bar = enum { none, hover, hover_wide, selected, selected_wide };
fn drawBar(win: vaxis.Window, row: usize, bar: Bar) void {
    if (row >= win.height) return;
    const wide = bar == .hover_wide or bar == .selected_wide;
    const colour = if (bar == .selected or bar == .selected_wide) bar_rgb else hover_rgb;
    // Over whatever background the row has, so a card runs behind it.
    const under = if (win.readCell(0, @intCast(row))) |cell| cell.style.bg else .default;
    win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = if (wide) "◗" else "▎", .width = 1 }, .style = .{ .fg = .{ .rgb = colour }, .bg = under } });
}
/// The rows that belong with row `c`: the run of non-blank rows around it
/// and the blank row that closes it.
fn groupAround(rows: []const sidebar.Row, c: usize) struct { first: usize, last: usize } {
    const blank = struct {
        fn is(row: sidebar.Row) bool {
            return row.text.len == 0 and !row.heading;
        }
    }.is;
    var first = c;
    while (first > 0 and !blank(rows[first - 1])) first -= 1;
    var last = c;
    while (last + 1 < rows.len and !blank(rows[last + 1])) last += 1;
    if (last + 1 < rows.len) last += 1;
    return .{ .first = first, .last = last };
}
/// Mouse columns as the list sees them, so column 0 is the list's first
/// column and the gutter is -1.
fn intoBody(event: Event) Event {
    var shifted = event;
    if (shifted == .mouse) shifted.mouse.col -= @intCast(gutter);
    return shifted;
}
fn draw(win: vaxis.Window, a: std.mem.Allocator, row: usize, text: []const u8, style: vaxis.Cell.Style) void {
    if (row >= win.height) return;
    const safe = m.display(a, text) catch return;
    _ = win.printSegment(.{ .text = safe, .style = style }, .{ .row_offset = @intCast(row), .wrap = .none });
}
