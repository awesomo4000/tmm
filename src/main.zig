// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const vaxis = @import("vaxis");
const tmux = @import("libtmux");
const m = @import("model.zig");
const sidebar = @import("sidebar.zig");
const backend = @import("backend.zig");
const region_mod = @import("region.zig");
const panes_mod = @import("panes.zig");
const surface = @import("surface.zig");
const focuskey = @import("focuskey.zig");
const png = @import("png.zig");
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, address: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(message, address);
    }
}.call);
pub const std_options: std.Options = .{ .log_level = .err };
const new_button_col = 11; // "sessions" plus three spaces
const new_button_text = "[new]";
/// `key_release` is here because libvaxis posts an event kind only when the
/// union names it: without the field, releases are parsed and dropped.
const Event = union(enum) { key_press: vaxis.Key, key_release: vaxis.Key, mouse: vaxis.Mouse, winsize: vaxis.Winsize, snapshot: *backend.Snapshot, pty };
/// Narrowest sidebar and terminal region a drag may leave behind.
const min_pane = 8;
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
    \\       tmm [-L socket-name | -S socket-path] [--shell] [--split cols]
    \\       tmm [-L socket-name | -S socket-path] --dump
    \\Run beside an ordinary tmux client. Select a display before navigating.
    \\Mouse: hover highlights, click selects, wheel browses without selecting.
    \\Sessions: j/k or arrows to browse, Enter to switch the selected display.
    \\Click a server, display, session, or agent. b blinks the display. q exits.
    \\--dump prints a read-only JSON snapshot without opening the terminal UI.
    \\--shell splits the window: the sidebar on the left, a shell on the right.
    \\       The shell starts with the keyboard; the focus key moves focus
    \\       between the two, and q quits from the sidebar. Drag the divider
    \\       to resize. The shell is an ordinary one: tmux attach works in it.
    \\--focus-key names that key, default ctrl+`, or set TMM_FOCUS_KEY.
    \\       Spell it as f1-f20, insert, delete, home, end, page-up/down, an
    \\       arrow, or ctrl/alt/super/shift plus any of those or a character:
    \\       --focus-key ctrl+g. A key that types something needs a modifier.
    \\       tmm keeps the key, so nothing inside the region ever sees it; a
    \\       nested tmm given a different key stays reachable through it.
    \\--split sets the starting sidebar width in columns; it implies --shell.
    \\--panes composites a session's panes on the right instead of a shell.
    \\       tmm is the terminal for each pane; tmux still owns the session,
    \\       the processes and the scrollback. Implies the split layout.
    \\       Your tmux prefix works: tmm hands it and the key after it to
    \\       tmux, which runs your own bindings, repeat bindings included.
    \\       Pane dividers cannot be dragged.
    \\--session picks which session --panes shows; the newest by default.
    \\       Running tmm inside tmux, name a session other than your own:
    \\       compositing the one tmm sits in would resize tmm itself.
    \\
;
/// Printed under a rejected `--focus-key`, so the fix does not need --help.
const focus_key_hint =
    \\Spell it f1-f20, insert, delete, home, end, page-up, page-down, an arrow,
    \\or ctrl/alt/super/shift plus one of those or a character: ctrl+g.
    \\
;
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    // Before any terminal exists: the hook is read on every PNG transmission
    // and a terminal built without it drops them.
    png.install();
    var args = init.minimal.args.iterate();
    _ = args.next();
    var opts: tmux.ServerOptions = .{};
    var initial_client: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var dump = false;
    var shell = false;
    var panes = false;
    var panes_session: ?[]const u8 = null;
    var split_request: ?u16 = null;
    var focus_key_text: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--shell")) {
            shell = true;
        } else if (std.mem.eql(u8, arg, "--panes")) {
            panes = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            panes_session = args.next() orelse return error.MissingSessionName;
        } else if (std.mem.eql(u8, arg, "--split")) {
            const text = args.next() orelse return error.MissingSplitWidth;
            split_request = std.fmt.parseInt(u16, text, 10) catch return error.InvalidSplitWidth;
            shell = true;
        } else if (std.mem.eql(u8, arg, "--focus-key")) {
            focus_key_text = args.next() orelse return error.MissingFocusKey;
        } else if (std.mem.eql(u8, arg, "--label")) {
            label = args.next() orelse return error.MissingLabel;
        } else return error.UnknownArgument;
    }
    if (opts.socket_name != null and opts.socket_path != null) return error.ConflictingSocketSelectors;
    // Resolved before anything is opened, because a key nobody can press is
    // a usage error and not a runtime one: failing here still leaves the
    // terminal as the user had it, and says what was wrong with the spelling
    // rather than unwinding a stack at them.
    const focus_key_spelling = focus_key_text orelse
        init.environ_map.get(focuskey.env_var) orelse focuskey.default_text;
    const focus_key = focuskey.parse(focus_key_spelling) catch |err| {
        var buf: [512]u8 = undefined;
        var out = std.Io.File.stderr().writer(io, &buf);
        try out.interface.print("tmm: {s}: {s}\n{s}", .{
            focus_key_spelling,
            switch (err) {
                error.EmptyFocusKey => "no key named",
                error.UnknownFocusKey => "not a key tmm knows",
                error.UnknownFocusModifier => "not a modifier tmm knows",
                error.FocusKeyNeedsModifier => "types something, so it needs ctrl, alt or super with it",
                error.FocusKeyTooLong => "too long to be a key",
            },
            focus_key_hint,
        });
        try out.interface.flush();
        // Exit rather than returning the error: this is a typo in an
        // argument, and an error return trace under it reads as a crash
        // in tmm. Nothing is open yet, which is the reason the key is
        // resolved this early.
        std.process.exit(1);
    };
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
    // Compositing the session tmm is running in cannot work: tmm sizes the
    // session, tmux re-tiles it, and the window being re-tiled holds tmm's
    // own pane, so tmm shrinks itself a step at a time down to a few columns
    // and draws no region at all. Caught here, before the terminal is
    // opened, because the collapse reads as tmm being broken rather than
    // aimed at the wrong session -- and because the fix is one flag away.
    if (panes) if (panes_mod.hostSession(a, io, .{
        .socket = opts.socket_path,
        .label = opts.socket_name,
        .session = panes_session,
    }, init.environ_map)) |host| {
        defer a.free(host);
        if (panes_session == null or std.mem.eql(u8, panes_session.?, host)) {
            var buf: [2048]u8 = undefined;
            var out = std.Io.File.stderr().writer(io, &buf);
            try out.interface.print(
                \\tmm: --panes cannot composite "{s}", the session this tmm is running in.
                \\Sizing it would re-tile the window holding this pane, which shrinks tmm
                \\and then shrinks it again. Name another session instead:
                \\
            , .{host});
            if (panes_mod.sessionNames(a, io, .{
                .socket = opts.socket_path,
                .label = opts.socket_name,
            })) |names| {
                defer {
                    for (names) |name| a.free(name);
                    a.free(names);
                }
                var other: usize = 0;
                for (names) |name| {
                    if (std.mem.eql(u8, name, host)) continue;
                    try out.interface.print("    tmm --panes --session {s}\n", .{name});
                    other += 1;
                }
                if (other == 0) try out.interface.writeAll(
                    "    (this server has no other session; create one first)\n",
                );
            } else try out.interface.writeAll("    tmm --panes --session NAME\n");
            try out.interface.flush();
            std.process.exit(1);
        }
    };
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    // Ask the outer terminal to report key releases, which libvaxis does not
    // by default: its KittyFlags leaves `report_events` off, so the terminal
    // sends presses only and nothing downstream can report what it never
    // received. A program in the region that wants hold-to-move, or wants to
    // see a chord come apart, needs them -- and a program that does not ask
    // is unaffected, because the encoder drops a release unless the program
    // inside turned the same flag on.
    var vx = try vaxis.init(io, a, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(a, tty.writer());
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setMouseMode(tty.writer(), true);
    // The terminal region, when asked for. One libghostty-vt terminal on one
    // pty running one shell: this is tmm drawing two things into its own
    // window, not a multiplexer. A tmux client inside it is an ordinary tmux
    // client. Created before the backend tasks so a failure here exits before
    // anything else needs tearing down.
    var split: ?u16 = split_request;
    var compositor: ?*panes_mod.Compositor = null;
    if (panes) {
        compositor = try panes_mod.Compositor.create(a, io, .{
            .socket = opts.socket_path,
            .label = opts.socket_name,
            .session = panes_session,
        }, init.environ_map.get("TMM_INPUT_LOG"));
        // Proof scaffolding for tests/pane_use_after_free.py; both off
        // unless asked for.
        if (compositor) |c| {
            c.uaf_log = init.environ_map.get("TMM_UAF_LOG");
            c.unsafe_lookup = init.environ_map.get("TMM_UNSAFE_PANE_LOOKUP") != null;
            // Before any key can be pressed: without it every key goes to
            // the pane as a byte and no tmux binding fires.
            c.loadPrefix();
        }
    }
    var compositor_task = if (compositor) |c|
        try io.concurrent(paneWorker, .{ io, c, &loop })
    else
        null;
    defer if (compositor) |c| {
        // Shut the stream down rather than closing it: this has to end the
        // child so the worker blocked in `next` returns, and `cancel` awaits
        // that worker. Closing here would free the stream while the worker
        // still held it, and `destroy` would then free it a second time --
        // which it did, deterministically, on every `--panes` exit.
        c.stream.shutdown();
        if (compositor_task) |*t| t.cancel(io);
        c.destroy();
    };
    var region: ?*region_mod.Region = null;
    if (shell and !panes) {
        const argv = try ca.dupe([]const u8, &.{init.environ_map.get("SHELL") orelse "/bin/sh"});
        // Sized provisionally: vaxis has not measured the window yet, and will
        // not until the first resize event, so the real size is applied by the
        // first frame below. The child sees one resize at startup either way.
        region = try region_mod.Region.create(a, io, argv, 80, 24, init.environ_map.get("TMM_INPUT_LOG"));
    }
    var region_task = if (region) |r| try io.concurrent(ptyWorker, .{ io, r, &loop }) else null;
    defer if (region) |r| {
        // Close the pty before joining: the reader task parks in a read on
        // it, and closing is what ends that read. Cancelling first would
        // leave the cancel racing a blocking read instead.
        r.closePty();
        if (region_task) |*t| t.cancel(io);
        r.destroy();
    };
    var transmitter: ImageTransmitter = .{ .vx = &vx, .tty = &tty, .alloc = a };
    const images = transmitter.sink();
    // The shell starts with the keyboard, because `--shell` is launched to
    // work in: the sidebar is the thing you turn to, not the thing you begin
    // at. F12 moves focus back, and so does the shell exiting, so `q` is
    // still reachable without one. `--panes` is left on the sidebar, where a
    // pane is chosen by clicking it.
    var focus: enum { sidebar, region } = if (shell and !panes) .region else .sidebar;
    // Built once, because the label is only known at runtime now and the
    // status line is drawn every frame.
    const hint_region = try std.fmt.allocPrint(ca, "{s} sidebar", .{focus_key.label()});
    const hint_sidebar = try std.fmt.allocPrint(ca, "j/k move  {s} shell  q quit", .{focus_key.label()});
    var dragging = false;
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
    var sidebar_width: u16 = vx.window().width;
    var sidebar_height: u16 = vx.window().height;
    var pressed: ?[]const u8 = null;
    defer if (pressed) |p| a.free(p);
    var offset: usize = 0;
    var editor: ?Editor = null;
    defer if (editor) |*e| e.deinit(a);
    var error_text: ?[]const u8 = null;
    defer if (error_text) |e| a.free(e);
    // A frame budget, so the loop is not always mid-draw when a key lands.
    // Without one tmm drew as fast as output arrived, which left no moment
    // in which a keypress could be picked up first. movy paces a game loop
    // to an absolute deadline and sleeps the remainder for the same reason.
    // `TMM_FRAME_BUDGET_MS=0` turns it off, for measuring what it buys.
    const frame_budget_ns: u64 = budget: {
        const text = init.environ_map.get("TMM_FRAME_BUDGET_MS") orelse break :budget 16 * std.time.ns_per_ms;
        const ms = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch break :budget 16 * std.time.ns_per_ms;
        break :budget ms * std.time.ns_per_ms;
    };
    var last_draw: std.Io.Timestamp = .now(io, .awake);
    var frames: ?FrameLog = if (init.environ_map.get("TMM_FRAME_LOG")) |path|
        .{ .io = io, .alloc = a, .path = path }
    else
        null;
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
            // A motion that changes nothing in the sidebar is dropped, but
            // not while a divider drag is in flight: there the motion *is*
            // the event, and the sidebar hit is null throughout.
            if (!dragging and mouse_cursor and cursor == mouseHit(rows, offset, event.mouse, sidebar_width, sidebar_height, column_width)) continue;
        }
        // A `.pty` event carries nothing: the worker has already fed the
        // output, and the draw below reads the newest state. So a backlog of
        // them collapses into the single draw they all ask for. Without this
        // a keypress waits behind every queued redraw, because one 512-slot
        // FIFO carries both: a program writing continuously pushed key
        // latency past a second, while a quiet one stayed under a
        // millisecond. See tests/keylag.py.
        if (event == .pty) {
            while (try loop.tryEvent()) |next| {
                if (next != .pty) {
                    pending_event = next;
                    break;
                }
            }
            // A real event found behind the backlog is handled before the
            // draw those wakeups asked for. A redraw one iteration late is
            // invisible; a key held back by one is felt.
            if (pending_event != null) continue;
        }
        var action: ?sidebar.Action = null;
        var reveal = false;
        const old_key = if (cursor) |c| if (c < rows.len) try a.dupe(u8, rows[c].key) else null else null;
        defer if (old_key) |k| a.free(k);
        switch (event) {
            .pty => {},
            .winsize => |ws| {
                try vx.resize(a, tty.writer(), ws);
                // The outer terminal reports its own pixel size here, and
                // dividing gives the cell size, which is the only thing a
                // program inside a pane or the region can use to decide it
                // may draw an image. A terminal that reports no pixels
                // leaves this zero and nothing is claimed on its behalf.
                if (ws.x_pixel != 0 and ws.y_pixel != 0 and
                    ws.cols != 0 and ws.rows != 0)
                {
                    const cw = ws.x_pixel / ws.cols;
                    const ch = ws.y_pixel / ws.rows;
                    if (region) |r| r.setCellSize(cw, ch);
                    if (compositor) |c| c.setCellSize(cw, ch);
                }
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
            .mouse => |mouse| mouse_event: {
                mouse_cursor = true;
                if (region != null or compositor != null) {
                    const divider: i32 = split.?;
                    if (dragging) {
                        if (mouse.type == .release) dragging = false else split = clampSplit(mouse.col, vx.window().width);
                        break :mouse_event;
                    }
                    if (mouse.type == .press and mouse.button == .left and mouse.col == divider) {
                        dragging = true;
                        break :mouse_event;
                    }
                    // Clicking the shell focuses it, and once it has focus
                    // the mouse goes to the child the way the keyboard does.
                    // Forwarding only while focused keeps a stray hover from
                    // reaching a program the user is not working in.
                    if (mouse.col > divider) {
                        if (mouse.type == .press) focus = .region;
                        if (focus == .region) {
                            const col = mouse.col - @as(i16, @intCast(divider + 1));
                            if (region) |r| r.sendMouse(mouse, col, mouse.row);
                            if (compositor) |c| c.sendMouse(mouse, col, mouse.row);
                        }
                        break :mouse_event;
                    }
                    if (mouse.type == .press) focus = .sidebar;
                }
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
                        };
                        if (pressed) |p| a.free(p);
                        pressed = null;
                    }
                }
            },
            // A release is for the region and for nothing else: the sidebar
            // acts on presses, and treating a release as one would move the
            // cursor twice for a single keystroke.
            .key_release => |key| {
                if (focus == .region and (region != null or compositor != null)) {
                    if (!focus_key.matches(key))
                        forwardKey(region, compositor, key, .release);
                }
            },
            .key_press => |key| key_event: {
                mouse_cursor = false;
                if (pressed) |p| a.free(p);
                pressed = null;
                if (region != null or compositor != null) {
                    // One key moves focus, named by --focus-key and
                    // defaulting to ctrl+` -- deliberately not a plausible
                    // shell or tmux binding, because ctrl+b belongs to the
                    // tmux that may be running inside. See focuskey.zig.
                    if (focus_key.matches(key)) {
                        focus = if (focus == .region) .sidebar else .region;
                        break :key_event;
                    }
                    if (focus == .region) {
                        forwardKey(region, compositor, key, .press);
                        // The rest of the queued keys go with it. A key bound
                        // for the region changes nothing the sidebar draws,
                        // so there is no reason to draw between two of them,
                        // and taking one per frame capped typing at the frame
                        // rate: ten keys pressed together arrived 24ms apart,
                        // over 250ms for the last. movy's loop drains its
                        // input every frame for the same reason.
                        while (try loop.tryEvent()) |next| {
                            const queued: vaxis.Key, const kind: surface.Action = switch (next) {
                                .key_press => |k| .{ k, .press },
                                .key_release => |k| .{ k, .release },
                                else => {
                                    pending_event = next;
                                    break;
                                },
                            };
                            // Focus moves on the press. The release that
                            // follows belongs to the side that now has the
                            // keyboard, and is dropped rather than delivered
                            // to a program that never saw the press.
                            if (focus_key.matches(queued)) {
                                if (kind == .press) focus = .sidebar;
                                break;
                            }
                            forwardKey(region, compositor, queued, kind);
                        }
                        break :key_event;
                    }
                }
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
        rows = try sidebar.rows(fa, servers.items, current_server, snapshot, target, label, init.environ_map.get("HOME"), if (compositor) |c| c.statusLookup() else .none);
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
        var stamp: std.Io.Timestamp = if (frames != null) .now(io, .awake) else .zero;
        const full = vx.window();
        // The sidebar's content width, measured before the split is known so
        // that a first frame can size itself to what it has to show.
        var natural: u16 = new_button_col + new_button_text.len;
        for (rows) |row| {
            const safe = try m.display(fa, row.text);
            natural = @max(natural, full.gwidth(safe) +| 1);
        }
        // The split is kept as the width the user asked for, and clamped to
        // the window only here: the window is not measured until the first
        // resize event, so clamping any earlier collapses it to the minimum.
        if ((region != null or compositor != null) and split == null) split = natural;
        const win = if (region == null and compositor == null) full else full.child(.{
            .width = clampSplit(split.?, full.width),
            .height = full.height,
        });
        sidebar_width = win.width;
        sidebar_height = win.height;
        column_width = @min(win.width, natural);
        const visible: usize = win.height -| 4;
        offset = @min(offset, rows.len -| visible);
        if (reveal) if (cursor) |c| {
            if (c < offset) offset = c;
            if (c >= offset + visible) offset = c + 1 -| visible;
        };
        if (region) |r| {
            if (r.exited.load(.acquire)) focus = .sidebar;
            r.resize(full.width -| (win.width + 1), full.height) catch {};
        }
        if (compositor) |c| {
            if (c.ended.load(.acquire)) focus = .sidebar;
            // tmux re-tiles to this and answers with a fresh layout; tmm
            // never sizes a pane itself.
            c.resize(full.width -| (win.width + 1), full.height);
        }
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
        if (win.height >= 1) draw(win, fa, win.height - 1, if (editor) |edit|
            if (edit.pending) "saving..." else "Enter save  Esc cancel"
        else if (region == null and compositor == null)
            "j/k move  q quit"
        else if (focus == .region)
            hint_region
        else
            hint_sidebar, .{ .fg = .{ .index = 8 } });
        if (frames) |*f| stamp = f.mark(0, stamp);
        if (region != null or compositor != null) {
            const divider = win.width;
            for (0..full.height) |y| full.writeCell(divider, @intCast(y), .{
                .char = .{ .grapheme = "\u{2502}", .width = 1 },
                .style = .{ .fg = .{ .index = if (dragging) 14 else if (focus == .region) 6 else 8 } },
            });
            const region_width = full.width -| (divider + 1);
            if (region_width > 0) {
                const pane = full.child(.{ .x_off = divider + 1, .width = region_width, .height = full.height });
                if (region) |r| try r.draw(pane, images);
                if (compositor) |c| try c.draw(pane, images);
                // The sidebar hid the cursor above, so showing it here is
                // also what tells the user which side has the keyboard.
                const at = if (region) |r| r.cursor() else if (compositor) |c| c.cursor() else null;
                if (focus == .region) if (at) |c| {
                    if (c.col < region_width and c.row < full.height)
                        full.showCursor(divider + 1 + c.col, c.row);
                };
            }
        }
        if (frames) |*f| stamp = f.mark(1, stamp);

        // Wait out the rest of the frame budget, and hand over the moment
        // input arrives: a frame rendered late is invisible, and the key
        // that interrupted it is now in front of the render rather than
        // behind it.
        //
        // Only the render waits. Everything above it is this frame's layout
        // -- the clamped split, the scroll offset, the hit-test extents and
        // the resize the region is owed -- and skipping that is not a
        // deferred redraw but a dropped update. Waiting earlier cost the
        // region its resize and left the divider a cell short of the drag.
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
        if (frames) |*f| {
            _ = f.mark(2, stamp);
            f.flush();
        }
    }
}
/// The display side of `surface.ImageSink`: it owns the vaxis instance and
/// the real terminal, which is what transmitting an image needs.
const ImageTransmitter = struct {
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    alloc: std.mem.Allocator,

    fn sink(self: *ImageTransmitter) surface.ImageSink {
        return .{ .ctx = self, .transmit = transmit };
    }

    fn transmit(
        ctx: ?*anyopaque,
        bytes: []const u8,
        width: u16,
        height: u16,
        format: vaxis.Image.TransmitFormat,
    ) anyerror!vaxis.Image {
        const self: *ImageTransmitter = @ptrCast(@alignCast(ctx.?));
        // Base64, because `transmitPreEncodedImage` writes what it is given
        // and the protocol carries the payload inside an APC: a pixel that
        // happens to be 0x1b would end the sequence in the middle of the
        // image. "PreEncoded" means the caller encodes, which is this.
        const encoder = std.base64.standard.Encoder;
        const encoded = try self.alloc.alloc(u8, encoder.calcSize(bytes.len));
        defer self.alloc.free(encoded);
        _ = encoder.encode(encoded, bytes);
        // A terminal without kitty graphics reports that here, and the
        // surface leaves the image undrawn.
        return self.vx.transmitPreEncodedImage(self.tty.writer(), encoded, width, height, format);
    }
};

/// Hand a key to whichever of the two owns the region.
fn forwardKey(region: ?*region_mod.Region, compositor: ?*panes_mod.Compositor, key: vaxis.Key, action: surface.Action) void {
    if (region) |r| r.sendKey(key, action);
    if (compositor) |c| c.sendKey(key, action);
}

/// Where a frame's time goes, written to `TMM_FRAME_LOG` as a mean and a
/// peak over a window of frames rather than a line each. A line per frame
/// would cost an open and a write inside the thing being measured, which is
/// how a profile ends up reporting its own overhead.
const FrameLog = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []const u8,
    frames: u32 = 0,
    sums: [3]u64 = @splat(0),
    peaks: [3]u64 = @splat(0),

    const window = 60;

    /// Charge the time since `from` to `phase` and return the reading, so
    /// each phase ends where the next begins and nothing falls between.
    fn mark(self: *FrameLog, phase: usize, from: std.Io.Timestamp) std.Io.Timestamp {
        const now: std.Io.Timestamp = .now(self.io, .awake);
        const ns: u64 = @intCast(@max(0, from.durationTo(now).nanoseconds));
        self.sums[phase] += ns;
        self.peaks[phase] = @max(self.peaks[phase], ns);
        return now;
    }

    fn flush(self: *FrameLog) void {
        self.frames += 1;
        if (self.frames < window) return;
        const n: f64 = @floatFromInt(self.frames);
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
            }
        }.f;
        const line = std.fmt.allocPrint(
            self.alloc,
            "frames={d} sidebar mean={d:.2} peak={d:.2} | region mean={d:.2} peak={d:.2} " ++
                "| render mean={d:.2} peak={d:.2} | frame mean={d:.2} ms\n",
            .{
                self.frames,
                ms(self.sums[0]) / n, ms(self.peaks[0]),
                ms(self.sums[1]) / n, ms(self.peaks[1]),
                ms(self.sums[2]) / n, ms(self.peaks[2]),
                ms(self.sums[0] + self.sums[1] + self.sums[2]) / n,
            },
        ) catch return;
        defer self.alloc.free(line);
        self.frames = 0;
        self.sums = @splat(0);
        self.peaks = @splat(0);
        var file = std.Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = false }) catch return;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return;
        _ = file.writePositionalAll(self.io, line, st.size) catch {};
    }
};

fn mouseHit(rows: []const sidebar.Row, offset: usize, mouse: vaxis.Mouse, width: u16, height: u16, column_width: u16) ?usize {
    if (mouse.row < 2 or mouse.row >= @as(i32, height) - 2 or mouse.col < 0 or mouse.col >= @min(width, column_width)) return null;
    const i = offset + @as(usize, @intCast(mouse.row - 2));
    if (i >= rows.len or rows[i].action == null) return null;
    if (rows[i].action.? == .new_session and (mouse.col < new_button_col or mouse.col >= new_button_col + new_button_text.len)) return null;
    return if (rows[i].continuation and i > 0) i - 1 else i;
}
/// Keep both sides of the divider usable whatever the pointer does.
fn clampSplit(col: i32, width: u16) u16 {
    const upper: i32 = @as(i32, width) - (min_pane + 1);
    if (upper < min_pane) return min_pane;
    return @intCast(std.math.clamp(col, min_pane, upper));
}
/// Read the region's child forever, feeding its output to the terminal and
/// nudging the UI. The loop ends when the pty closes, which is either the
/// child exiting or shutdown closing it underneath us.
/// Read the compositor's control stream forever, applying each event and
/// nudging the UI when one changed something worth drawing. The loop ends
/// when the stream closes, which is tmux exiting or shutdown closing it.
fn paneWorker(io: std.Io, c: *panes_mod.Compositor, loop: *vaxis.Loop(Event)) void {
    _ = io;
    while (true) {
        const event = c.stream.next() catch break orelse break;
        const changed = c.apply(event) catch continue;
        if (!changed) continue;
        // A dropped wake is harmless: the draw always reads the newest state.
        _ = loop.tryPostEvent(.pty) catch break;
    }
    c.ended.store(true, .release);
    _ = loop.tryPostEvent(.pty) catch {};
}

fn ptyWorker(io: std.Io, region: *region_mod.Region, loop: *vaxis.Loop(Event)) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = region.pty.read(io, &buf) catch break;
        if (n == 0) break;
        region.feed(buf[0..n]);
        // A dropped wake is harmless: the draw always reads the newest state,
        // and the event that filled the queue will carry this output with it.
        _ = loop.tryPostEvent(.pty) catch break;
    }
    region.exited.store(true, .release);
    _ = loop.tryPostEvent(.pty) catch {};
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
fn draw(win: vaxis.Window, a: std.mem.Allocator, row: usize, text: []const u8, style: vaxis.Cell.Style) void {
    if (row >= win.height) return;
    const safe = m.display(a, text) catch return;
    _ = win.printSegment(.{ .text = safe, .style = style }, .{ .row_offset = @intCast(row), .wrap = .none });
}
