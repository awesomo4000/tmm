// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The compositor: one `Surface` per tmux pane, fed from control mode.
//!
//! tmux keeps sessions, windows, panes, processes, scrollback and
//! persistence. tmm is the terminal. Neither direction goes through tmux's
//! own emulation, which is what makes kitty work through a stock tmux:
//!
//!   out   the pane's raw bytes reach a control client in `%output` before
//!         tmux's parser sees them (window.c: control_write_output is called
//!         at 1653, input_parse_pane only at 1655), so kitty graphics arrive
//!         verbatim even though tmux's screen model has no cell for them
//!   in    `send-keys -H` is a raw byte channel, so tmm encodes a key itself
//!
//! Negotiation rides the same path. A program turning on the kitty keyboard
//! protocol writes `CSI > flags u`, which is pane output, so it arrives in
//! `%output` and lands in that pane's own terminal state. The surface then
//! encodes to those flags. tmux never has to understand the protocol.
//!
//! Layout comes from `%layout-change` and the geometry from `layout.zig`;
//! sizing goes the other way with `refresh-client -C`, which makes tmux
//! re-tile to the space tmm actually has and deliver SIGWINCH to the pane
//! processes. tmm never resizes a pane itself.

const std = @import("std");
const vaxis = @import("vaxis");
const control = @import("control.zig");
const cmstream = @import("cmstream.zig");
const layout = @import("layout.zig");
const surface = @import("surface.zig");
const sidebar = @import("sidebar.zig");
const tmuxkey = @import("tmuxkey.zig");

const Allocator = std.mem.Allocator;

/// One tmux pane: its id, where the layout puts it, and our terminal for it.
/// Set while a pane is alive and cleared just before it is freed. Only for
/// the proof in tests/pane_use_after_free.py: a freed Pane is poisoned, so a
/// pointer used past its lifetime reads something other than this.
const pane_alive: u64 = 0xA11_FE_1234_5678;

pub const Pane = struct {
    magic: u64 = pane_alive,
    /// With the `%` sigil, as tmux writes it everywhere else.
    id: []const u8,
    rect: layout.PaneRect,
    surface: surface.Surface,
    owner: *Compositor,

    /// Bytes this pane's terminal produced -- an encoded key, or a reply the
    /// library generated for a query the program made -- going back to the
    /// program as raw bytes. `send-keys -H` is what makes that possible, and
    /// is why the kitty encoding survives a tmux that cannot speak it.
    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Pane = @ptrCast(@alignCast(ctx.?));
        self.owner.sendKeys(self.id, bytes);
    }
};

/// How to reach a server as a one-shot command, appended to `argv`.
fn serverArgvInto(alloc: Allocator, opts: cmstream.Options, argv: *std.ArrayList([]const u8)) !void {
    try argv.append(alloc, opts.tmux_bin);
    if (opts.socket) |socket| {
        try argv.append(alloc, "-S");
        try argv.append(alloc, socket);
    } else if (opts.label) |label| {
        try argv.append(alloc, "-L");
        try argv.append(alloc, label);
    }
}

/// Run a tmux command and return its trimmed first line, or null. Caller frees.
fn ask(alloc: Allocator, io: std.Io, opts: cmstream.Options, args: []const []const u8) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    serverArgvInto(alloc, opts, &argv) catch return null;
    argv.appendSlice(alloc, args) catch return null;
    const result = std.process.run(alloc, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(4096),
    }) catch return null;
    alloc.free(result.stderr);
    defer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return null;
    const line = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (line.len == 0) return null;
    return alloc.dupe(u8, line) catch null;
}

/// The session holding the pane tmm itself is running in, when that pane is
/// on the very server tmm is about to composite. Null otherwise. Caller frees.
///
/// Compositing that session cannot work, and fails in a way that looks like
/// tmm is broken rather than misaimed. tmm sizes the session with
/// `refresh-client -C`, so tmux re-tiles it; that window contains tmm's own
/// pane, which therefore shrinks, so tmm recomputes a smaller region and
/// sizes it down again. Measured from a 200-column pane: 200, 132, 81, 30,
/// then 4 columns and stuck at the floor, with no region drawn at all.
///
/// Both halves have to be checked. `$TMUX_PANE` alone is not enough, because
/// pane ids are per-server and `%3` exists on every server, so a pane id from
/// another server would resolve here and name an innocent session. The server
/// is identified by asking both ends for `#{socket_path}`, which tmux
/// normalises -- addressing a server through `/private/tmp` still reports
/// `/tmp` -- so the two strings are comparable where the raw paths are not.
pub fn hostSession(alloc: Allocator, io: std.Io, opts: cmstream.Options, env: *const std.process.Environ.Map) ?[]u8 {
    const pane = env.get("TMUX_PANE") orelse return null;
    const tmux_env = env.get("TMUX") orelse return null;
    // `$TMUX` is socket,pid,session; only the socket is wanted here.
    const socket_end = std.mem.indexOfScalar(u8, tmux_env, ',') orelse tmux_env.len;
    const socket = tmux_env[0..socket_end];
    if (socket.len == 0) return null;

    const ours = ask(alloc, io, opts, &.{ "display-message", "-p", "#{socket_path}" }) orelse return null;
    defer alloc.free(ours);
    const theirs = ask(alloc, io, .{ .socket = socket, .tmux_bin = opts.tmux_bin }, &.{
        "display-message", "-p", "#{socket_path}",
    }) orelse return null;
    defer alloc.free(theirs);
    if (!std.mem.eql(u8, ours, theirs)) return null;

    return ask(alloc, io, opts, &.{ "display-message", "-p", "-t", pane, "#{session_name}" });
}

/// Session names on this server, newest first, for telling someone which one
/// to ask for. Caller frees the slice and each name.
pub fn sessionNames(alloc: Allocator, io: std.Io, opts: cmstream.Options) ?[][]u8 {
    const text = ask(alloc, io, opts, &.{
        "list-sessions", "-F", "#{session_name}",
    }) orelse return null;
    defer alloc.free(text);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |name| alloc.free(name);
        list.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r\n");
        if (name.len == 0) continue;
        list.append(alloc, alloc.dupe(u8, name) catch return null) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

pub const Compositor = struct {
    io: std.Io,
    alloc: Allocator,
    stream: *cmstream.Stream,

    /// Panes of the window being composited, keyed by id. Pointers are stable
    /// because a `Surface` must not move.
    panes: std.StringArrayHashMapUnmanaged(*Pane) = .empty,

    /// The window the session has active, with its `@` sigil, or empty until
    /// tmux says. Only this window's layout is composited.
    ///
    /// Without it any `%layout-change` was adopted, so a split in another
    /// window switched what tmm was showing and destroyed the panes it had,
    /// because a layout names only its own window's panes. tmux reports the
    /// active window with `%session-window-changed`, so the two are now
    /// distinguished: which window is current, and which window changed.
    active_window: []const u8 = "",

    /// The window we are showing, with its `@` sigil, or empty before the
    /// first layout.
    window: []const u8 = "",

    /// Which pane has the keyboard, or empty for none.
    focused: []const u8 = "",

    /// Size last given to tmux. tmux tiles to this, so the rects we get back
    /// are already in these coordinates and need no scaling.
    cols: u16 = 0,
    rows: u16 = 0,

    /// Guards `panes`, `window`, and the rects. Surfaces guard themselves.
    mutex: std.Io.Mutex = .init,

    /// Raised when the control stream ends.
    ended: std.atomic.Value(bool) = .init(false),

    /// The outer terminal's cell size in pixels, or zero before it is known.
    /// Kept here as well as on each surface so a pane created later gets it,
    /// since panes come and go and the cell size is a property of the display.
    cell_width: u32 = 0,
    cell_height: u32 = 0,

    input_log: ?[]const u8 = null,

    /// tmux's `prefix` and `prefix2`, as read from the server at attach, or
    /// null for a prefix that is unset or that tmm cannot recognise.
    ///
    /// Asked for rather than assumed: a prefix is the one binding that has to
    /// match what the person configured, and `C-b` is only the default.
    prefix: [2]?tmuxkey.Chord = @splat(null),

    /// Where tmm believes tmux has left this client's key table, which is
    /// what decides whether a press goes to tmux or to the pane.
    ///
    /// Mirrored here rather than read back from tmux, because reading it
    /// means `Stream.request` -- a write then a read -- and the display
    /// thread cannot do that safely while the event worker is on the same
    /// stream (see `seed`). Only this thread touches these fields: `sendKey`
    /// is reached from the display thread alone.
    ///
    /// `repeating` is the state a `-r` binding leaves behind. tmux keeps the
    /// table at `prefix` for `repeat-time` after running one, so the key can
    /// be pressed again without the prefix, and every repeat re-arms that
    /// window -- measured, not assumed: five repeats 500ms apart all ran,
    /// across 2.5s of a 700ms window. Getting this wrong is not a missing
    /// convenience: without it the second `C-h` of a resize takes the byte
    /// path and the pane receives 0x08, and `C-j` would deliver 0x0a to
    /// whatever is reading there.
    prefix_state: enum { none, after_prefix, repeating } = .none,

    /// When the current repeat window closes. Only meaningful in `repeating`.
    repeat_deadline: ?std.Io.Timestamp = null,

    /// The keys in tmux's prefix table that were bound with `-r`, spelled as
    /// `tmuxkey.name` spells them so the two compare directly. Read from
    /// `list-keys` at attach, because which keys repeat is the person's
    /// choice and tmux will say.
    repeat_keys: std.StringHashMapUnmanaged(void) = .empty,

    /// `repeat-time` and `initial-repeat-time`, in milliseconds, as the
    /// server reports them. A zero `initial-repeat-time` means the first
    /// press uses `repeat-time`, which is what tmux documents.
    repeat_ms: u32 = 500,
    initial_repeat_ms: u32 = 0,

    /// How to reach this server, for the one-shot `capture-pane` that seeds a
    /// pane. Kept because that command must not go down the control stream:
    /// see `seed`.
    opts: cmstream.Options,

    /// Proof scaffolding, both off unless the environment asks: reinstate the
    /// lookup that released the lock before using the pane, and where to
    /// report a pane used after it was freed.
    unsafe_lookup: bool = false,
    uaf_log: ?[]const u8 = null,

    pub fn create(
        alloc: Allocator,
        io: std.Io,
        opts: cmstream.Options,
        input_log: ?[]const u8,
    ) !*Compositor {
        const self = try alloc.create(Compositor);
        errdefer alloc.destroy(self);
        self.* = .{
            .io = io,
            .alloc = alloc,
            .stream = try .open(alloc, io, opts),
            .input_log = input_log,
            .opts = opts,
        };
        return self;
    }

    pub fn destroy(self: *Compositor) void {
        const alloc = self.alloc;
        for (self.panes.values()) |pane| {
            pane.surface.deinit();
            alloc.free(pane.id);
            alloc.destroy(pane);
        }
        self.panes.deinit(alloc);
        var repeats = self.repeat_keys.keyIterator();
        while (repeats.next()) |key| alloc.free(key.*);
        self.repeat_keys.deinit(alloc);
        if (self.window.len != 0) alloc.free(self.window);
        if (self.active_window.len != 0) alloc.free(self.active_window);
        if (self.focused.len != 0) alloc.free(self.focused);
        self.stream.close();
        alloc.destroy(self);
    }

    /// Tell tmux how much room it has. It re-tiles, delivers SIGWINCH to the
    /// pane processes itself, and answers with a fresh `%layout-change`.
    pub fn resize(self: *Compositor, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
        const cmd = control.Command.refreshSize(self.alloc, cols, rows) catch return;
        defer self.alloc.free(cmd);
        self.stream.send(cmd) catch {};
    }

    /// Pass the display's cell size down, so a program in a pane can find out
    /// how big a cell is and decide it can draw an image. Panes have no pixel
    /// geometry of their own: see `Surface.cell_width`.
    pub fn setCellSize(self: *Compositor, width: u32, height: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cell_width == width and self.cell_height == height) return;
        self.cell_width = width;
        self.cell_height = height;
        for (self.panes.values()) |pane| pane.surface.setCellSize(width, height);
    }

    fn sendKeys(self: *Compositor, pane: []const u8, bytes: []const u8) void {
        // Formatted on the stack: this is the key path. Three characters per
        // byte plus the command and the pane id, and an encoded key is at
        // most 128 bytes, so the buffer only ever falls short for a paste,
        // which has no deadline and can afford the allocator.
        var buf: [512]u8 = undefined;
        if (control.Command.sendKeysHexBuf(&buf, pane, bytes)) |cmd| {
            self.stream.send(cmd) catch {};
            return;
        } else |_| {}
        const cmd = control.Command.sendKeysHex(self.alloc, pane, bytes) catch return;
        defer self.alloc.free(cmd);
        self.stream.send(cmd) catch {};
    }

    /// Whether this is the window we should be showing. True for any window
    /// until tmux has named the active one, so a display comes up at attach
    /// rather than waiting for a window switch.
    fn isActiveWindow(self: *Compositor, window: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_window.len == 0) return true;
        return std.mem.eql(u8, self.active_window, window);
    }

    /// Ask which window the session has active, then show it.
    ///
    /// A one-shot for the same reason as `seed` and `adoptWindow`: a reply
    /// matched by arrival order on the control stream races the keystrokes
    /// the display thread writes to it.
    fn adoptActiveWindow(self: *Compositor, session: []const u8) void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        argv.append(self.alloc, self.opts.tmux_bin) catch return;
        if (self.opts.socket) |socket| {
            argv.appendSlice(self.alloc, &.{ "-S", socket }) catch return;
        } else if (self.opts.label) |label| {
            argv.appendSlice(self.alloc, &.{ "-L", label }) catch return;
        }
        argv.appendSlice(self.alloc, &.{
            "display-message", "-p", "-t", session, "#{window_id}",
        }) catch return;

        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64),
        }) catch return;
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return;
        const window = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (window.len < 2 or window[0] != '@') return;

        self.mutex.lockUncancelable(self.io);
        if (self.active_window.len != 0) self.alloc.free(self.active_window);
        self.active_window = self.alloc.dupe(u8, window) catch "";
        const adopted = self.active_window;
        self.mutex.unlock(self.io);
        if (adopted.len != 0) self.adoptWindow(adopted) catch {};
    }

    /// Learn a window's panes by asking tmux where they are.
    ///
    /// tmux sends a layout when one changes, not when a client starts looking
    /// at a window, and a window switch reports only
    /// `%session-window-changed`. Two things were measured and rejected
    /// before this: `refresh-client -l` answers with a bare `%begin`/`%end`
    /// and resends nothing, and `#{window_visible_layout}` is JSON in this
    /// tmux while `%layout-change` carries the classic checksum form, so the
    /// two cannot share a parser.
    ///
    /// `list-panes` gives the geometry directly, which is what the layout
    /// string was being parsed for anyway. A one-shot subprocess rather than
    /// a request on the control stream, for the reason `seed` is: a reply
    /// matched by arrival order races the keystrokes the display thread
    /// writes to the same stdin. Window switches are human-paced.
    fn adoptWindow(self: *Compositor, window: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, self.opts.tmux_bin);
        if (self.opts.socket) |socket| {
            try argv.appendSlice(self.alloc, &.{ "-S", socket });
        } else if (self.opts.label) |label| {
            try argv.appendSlice(self.alloc, &.{ "-L", label });
        }
        try argv.appendSlice(self.alloc, &.{
            "list-panes", "-t", window, "-F",
            "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active}",
        });

        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64 * 1024),
        }) catch return;
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return;

        var rects: std.ArrayList(layout.PaneRect) = .empty;
        defer rects.deinit(self.alloc);
        // Which pane tmux has active, so the keyboard starts where tmux
        // already points rather than at whichever pane happened to be
        // created first. Without it tmm typed into %0 while tmux considered
        // %1 active, so every binding acted on a pane other than the one
        // being typed in until something clicked.
        var active: ?[]const u8 = null;
        var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " ");
            const id_text = fields.next() orelse continue;
            if (id_text.len < 2 or id_text[0] != '%') continue;
            const id = std.fmt.parseInt(u32, id_text[1..], 10) catch continue;
            const x = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            const y = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            const w = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            const h = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            if (fields.next()) |flag| if (std.mem.eql(u8, flag, "1")) {
                active = id_text;
            };
            try rects.append(self.alloc, .{ .id = id, .x = x, .y = y, .w = w, .h = h });
        }
        if (rects.items.len == 0) return;
        try self.applyRects(window, rects.items);
        if (active) |id| self.focus(id) catch {};
    }

    /// Apply a layout string: add panes that appeared, drop those that went,
    /// and resize the rest. Pane terminals are sized from the layout, never
    /// guessed, so they agree with what tmux told the process.
    fn applyLayout(self: *Compositor, window: []const u8, spec: []const u8) !void {
        const rects = try layout.parse(self.alloc, spec);
        defer self.alloc.free(rects);
        return self.applyRects(window, rects);
    }

    /// Bring the pane set in line with `rects`: add what appeared, drop what
    /// went, resize the rest. Shared by the layout string tmux pushes and the
    /// geometry asked for after a window switch, so a pane is created and
    /// destroyed in exactly one place.
    fn applyRects(self: *Compositor, window: []const u8, rects: []const layout.PaneRect) !void {

        self.mutex.lockUncancelable(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);

        if (!std.mem.eql(u8, self.window, window)) {
            if (self.window.len != 0) self.alloc.free(self.window);
            self.window = try self.alloc.dupe(u8, window);
        }

        var live: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer live.deinit(self.alloc);

        // Panes created by this pass, seeded once the lock is released.
        var fresh: std.ArrayList(*Pane) = .empty;
        defer fresh.deinit(self.alloc);

        for (rects) |rect| {
            const n = rect.id orelse continue;
            var buf: [24]u8 = undefined;
            const id = std.fmt.bufPrint(&buf, "%{d}", .{n}) catch continue;

            if (self.panes.get(id)) |pane| {
                pane.rect = rect;
                try pane.surface.resize(@intCast(rect.w), @intCast(rect.h));
                // Keyed by the pane's own id, never by `buf`: that is a stack
                // slice this loop reuses, so a key into it would dangle
                // before the sweep below reads it.
                try live.put(self.alloc, pane.id, {});
                continue;
            }
            const pane = try self.alloc.create(Pane);
            errdefer self.alloc.destroy(pane);
            pane.* = .{
                .magic = pane_alive,
                .id = try self.alloc.dupe(u8, id),
                .rect = rect,
                .surface = undefined,
                .owner = self,
            };
            errdefer self.alloc.free(pane.id);
            try pane.surface.init(self.io, self.alloc, @intCast(rect.w), @intCast(rect.h), .{
                .ctx = pane,
                .write = Pane.write,
            }, self.input_log);
            if (self.cell_width != 0 and self.cell_height != 0)
                pane.surface.setCellSize(self.cell_width, self.cell_height);
            try self.panes.put(self.alloc, pane.id, pane);
            try live.put(self.alloc, pane.id, {});
            if (self.focused.len == 0) self.focused = try self.alloc.dupe(u8, pane.id);
            // Seeded after the lock is released, below: it runs a tmux
            // command, and a keystroke needs this lock to find its pane.
            try fresh.append(self.alloc, pane);
        }

        var i: usize = 0;
        while (i < self.panes.count()) {
            const pane = self.panes.values()[i];
            if (live.contains(pane.id)) {
                i += 1;
                continue;
            }
            const key = pane.id;
            _ = self.panes.orderedRemove(key);
            // Safe to free here only because every reader of a `*Pane` holds
            // this lock for as long as it uses the pointer. Handing one out
            // and releasing the lock first, which is what `focusedPane` and
            // `paneAt` used to do, let a keystroke land on a pane this loop
            // had already destroyed.
            pane.magic = 0;
            pane.surface.deinit();
            self.alloc.free(pane.id);
            self.alloc.destroy(pane);
        }

        self.mutex.unlock(self.io);
        locked = false;
        // Seeding runs a `tmux capture-pane`, so it waits on another process.
        // Nothing else frees a pane -- only this thread does -- so these
        // pointers stay good without the lock held.
        for (fresh.items) |pane| self.seed(pane) catch {};
    }

    /// Seed a pane from tmux's own screen, so one that existed before we
    /// attached is not blank until it next writes.
    ///
    /// Through a one-shot `tmux capture-pane`, deliberately not through the
    /// control stream. `Stream.request` writes a command and then reads the
    /// reply that follows, matching by arrival order, and this runs on the
    /// event worker while the display thread is writing keystrokes to the
    /// same stdin. A `send-keys` landing between the two halves makes tmux
    /// answer that first, so the request takes the wrong `%begin`/`%end`
    /// block and the capture's own reply is left to be parsed as events.
    /// Panes appear at human pace, so a fork and exec here costs nothing
    /// that matters, and nothing on the keystroke path is shared.
    /// How to reach this server as a one-shot command, into `argv`.
    fn serverArgv(self: *Compositor, argv: *std.ArrayList([]const u8)) !void {
        return serverArgvInto(self.alloc, self.opts, argv);
    }

    /// Ask tmux which key is its prefix, so `sendKey` can recognise it.
    ///
    /// A one-shot command rather than the control stream, for the reason
    /// `seed` is one: a request writes and then reads, and this runs while
    /// the display thread may be writing keys to the same stdin. It happens
    /// once, at startup, so a fork and an exec cost nothing.
    ///
    /// A server that cannot be asked leaves both null, which disables the
    /// prefix path and leaves every key going to the pane as raw bytes --
    /// exactly how tmm behaved before this existed.
    pub fn loadPrefix(self: *Compositor) void {
        for ([_][]const u8{ "prefix", "prefix2" }, 0..) |opt, i| {
            const value = self.option(opt, 256) orelse continue;
            defer self.alloc.free(value);
            self.prefix[i] = tmuxkey.Chord.parse(std.mem.trim(u8, value, " \t\r\n"));
        }
        for ([_][]const u8{ "repeat-time", "initial-repeat-time" }, 0..) |opt, i| {
            const value = self.option(opt, 64) orelse continue;
            defer self.alloc.free(value);
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch continue;
            if (i == 0) self.repeat_ms = n else self.initial_repeat_ms = n;
        }
        self.loadRepeatKeys();
    }

    /// One `show-options -gv` as a one-shot command. Caller frees.
    fn option(self: *Compositor, name: []const u8, limit: usize) ?[]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        self.serverArgv(&argv) catch return null;
        argv.appendSlice(self.alloc, &.{ "show-options", "-gv", name }) catch return null;
        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(limit),
        }) catch return null;
        self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.alloc.free(result.stdout);
            return null;
        }
        return result.stdout;
    }

    /// Learn which prefix-table keys repeat, from `list-keys`.
    ///
    /// tmux prints a binding as the `bind-key` command that would recreate
    /// it, and a repeating one carries `-r`:
    ///
    ///     bind-key -r -T prefix C-h     resize-pane -L 1
    ///     bind-key    -T prefix z       resize-pane -Z
    ///
    /// So the set is read rather than guessed, and a binding the person
    /// changes is picked up by restarting tmm rather than by editing tmm.
    /// Only the `prefix` table is read: that is where a prefix sequence
    /// lands, and a `-r` key in a custom table reached by `switch-client -T`
    /// is not covered.
    fn loadRepeatKeys(self: *Compositor) void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        self.serverArgv(&argv) catch return;
        argv.appendSlice(self.alloc, &.{ "list-keys", "-T", "prefix" }) catch return;
        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv.items,
            // A binding can be a whole display-menu, so this is not small.
            .stdout_limit = .limited(1 << 20),
        }) catch return;
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return;

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            // A config with more repeating keys than this is not something to
            // allocate without bound for.
            if (self.repeat_keys.count() >= 256) return;
            const key = repeatKeyOf(line) orelse continue;
            const owned = self.alloc.dupe(u8, key) catch return;
            self.repeat_keys.put(self.alloc, owned, {}) catch {
                self.alloc.free(owned);
                return;
            };
        }
    }

    /// The key a `list-keys` line binds, if that line binds it with `-r`.
    ///
    /// Scanned by token rather than by column, because tmux pads the output
    /// to align it and the padding is not part of the grammar.
    fn repeatKeyOf(line: []const u8) ?[]const u8 {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, tokens.next() orelse return null, "bind-key")) return null;
        var repeat = false;
        // Options come before `-T`; `-r` is the only one that matters here.
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "-r")) {
                repeat = true;
            } else if (std.mem.eql(u8, token, "-T")) {
                _ = tokens.next() orelse return null; // the table name
                const key = tokens.next() orelse return null;
                return if (repeat) key else null;
            } else if (token.len != 0 and token[0] != '-') {
                // Past the options without seeing `-T`: not a form we read.
                return null;
            }
        }
        return null;
    }

    fn seed(self: *Compositor, pane: *Pane) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try self.serverArgv(&argv);
        try argv.appendSlice(self.alloc, &.{ "capture-pane", "-p", "-e", "-t", pane.id });

        const result = std.process.run(self.alloc, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(1 << 20),
        }) catch return;
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return;
        pane.surface.feed(std.mem.trimEnd(u8, result.stdout, "\n"));
    }

    /// Consume one control-mode event. Returns true when something changed
    /// that the UI should redraw for.
    ///
    /// Called only from `paneWorker`, on its own thread, and that matters for
    /// the pane pointers below. They are looked up under the lock and used
    /// after releasing it, which is the shape that `sendKey` was fixed for and
    /// `tests/pane_use_after_free.py` catches. It is safe *here* and nowhere
    /// else: panes are created and freed only by `applyRects`, which is
    /// reached only from this function, so the one thread that could free the
    /// pane is the thread already inside this call. Teardown is ordered to
    /// agree -- `main` closes the stream, which ends the worker's blocking
    /// `next`, then cancels the task, which awaits it, and only then calls
    /// `destroy`. The lock is here to keep the UI thread's readers off a pane
    /// this one is replacing; it was never protecting this thread from itself.
    ///
    /// Anything that moves pane creation or destruction onto another thread
    /// invalidates that, and the feeds below have to take the lock for the
    /// duration or copy what they need.
    pub fn apply(self: *Compositor, event: control.Event) !bool {
        switch (event) {
            .output => |o| {
                const bytes = try control.decodeAlloc(self.alloc, o.escaped);
                defer self.alloc.free(bytes);
                self.mutex.lockUncancelable(self.io);
                const pane = self.panes.get(o.pane);
                self.mutex.unlock(self.io);
                if (pane) |p| {
                    p.surface.feed(bytes);
                    return true;
                }
                return false;
            },
            .extended_output => |o| {
                const bytes = try control.decodeAlloc(self.alloc, o.escaped);
                defer self.alloc.free(bytes);
                self.mutex.lockUncancelable(self.io);
                const pane = self.panes.get(o.pane);
                self.mutex.unlock(self.io);
                if (pane) |p| {
                    p.surface.feed(bytes);
                    return true;
                }
                return false;
            },
            .layout_change => |l| {
                // A layout names only its own window's panes, so applying one
                // from a window we are not showing would destroy every pane
                // we have. Before tmux has said which window is active the
                // first layout to arrive is taken, which is what gets a
                // display up at attach.
                if (!self.isActiveWindow(l.window)) return false;
                // The visible layout is what this client sees, which is what
                // we are drawing; `layout` is the window's own.
                const spec = if (l.visible.len != 0) l.visible else l.layout;
                try self.applyLayout(l.window, spec);
                return true;
            },
            .session_changed => |session| {
                // Attaching reports the session but not which window it has
                // active, and tmux sends `%session-window-changed` only on a
                // change. Meanwhile it sends a layout for every window in the
                // session, so without asking, whichever arrived last was the
                // one displayed -- which could be a window the user is not
                // looking at.
                self.adoptActiveWindow(session.session);
                return true;
            },
            .session_window_changed => |w| {
                self.mutex.lockUncancelable(self.io);
                const same = std.mem.eql(u8, self.active_window, w.window);
                if (!same) {
                    if (self.active_window.len != 0) self.alloc.free(self.active_window);
                    self.active_window = self.alloc.dupe(u8, w.window) catch "";
                }
                self.mutex.unlock(self.io);
                if (same) return false;
                // tmux does not resend a layout for a window that has not
                // changed, so the new window's panes have to be asked for.
                self.adoptWindow(w.window) catch {};
                return true;
            },
            .window_pane_changed => |w| {
                if (!std.mem.eql(u8, w.window, self.window)) return false;
                try self.focus(w.pane);
                return true;
            },
            .exit => {
                self.ended.store(true, .release);
                return true;
            },
            else => return false,
        }
    }

    pub fn focus(self: *Compositor, pane: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.focusLocked(pane);
    }

    /// The pane at a point, in compositor coordinates. Caller holds the lock
    /// and must not keep the pointer past it: the event worker frees panes
    /// that disappear from the layout.
    fn paneAtLocked(self: *Compositor, col: u16, row: u16) ?*Pane {
        for (self.panes.values()) |pane| {
            const r = pane.rect;
            if (col >= r.x and col < r.x + r.w and row >= r.y and row < r.y + r.h)
                return pane;
        }
        return null;
    }

    fn focusedPaneLocked(self: *Compositor) ?*Pane {
        return self.panes.get(self.focused);
    }

    fn focusLocked(self: *Compositor, pane: []const u8) !void {
        if (std.mem.eql(u8, self.focused, pane)) return;
        if (!self.panes.contains(pane)) return;
        if (self.focused.len != 0) self.alloc.free(self.focused);
        self.focused = try self.alloc.dupe(u8, pane);
    }

    /// Give tmux a key to look up in its own key table, rather than giving
    /// the pane a byte. Returns false when this key is not tmm's business.
    ///
    /// Two presses go this way and no others: the prefix, and the one key
    /// after it. Everything else takes the raw `send-keys -H` path below,
    /// which is what keeps the kitty keyboard protocol and the keystroke
    /// deadline intact -- nothing here runs while someone is typing.
    fn routeToTmux(self: *Compositor, key: vaxis.Key, action: surface.Action) bool {
        if (self.prefix[0] == null and self.prefix[1] == null) return false;

        // A repeat window that has run out puts tmux back in `root`, where an
        // unbound key reaches the pane as it always did. Checked before the
        // state is read so a lapsed window never routes a key away.
        if (self.prefix_state == .repeating and self.repeatLapsed()) {
            self.prefix_state = .none;
            self.repeat_deadline = null;
        }

        // A release is not a tmux key. Swallowing the one that belongs to a
        // press we routed keeps the pane from seeing half a chord.
        if (action != .press) return self.prefix_state != .none;

        if (self.prefix_state == .none) {
            var is_prefix = false;
            for (self.prefix) |maybe| if (maybe) |chord| {
                if (chord.matches(key)) is_prefix = true;
            };
            if (!is_prefix) return false;
        }
        const opening = self.prefix_state == .none;

        var buf: [64]u8 = undefined;
        const spelled = tmuxkey.name(&buf, key) orelse {
            // No tmux spelling for this key, so tmux would drop it and fall
            // back to `root`. The pane must not be given the byte either, or
            // a chord nobody could bind would type into the program.
            self.prefix_state = .none;
            self.repeat_deadline = null;
            return !opening;
        };

        var cmd_buf: [96]u8 = undefined;
        const cmd = control.Command.sendKeyNameBuf(&cmd_buf, spelled) catch {
            self.prefix_state = .none;
            self.repeat_deadline = null;
            return !opening;
        };
        self.stream.send(cmd) catch {};

        if (opening) {
            // The prefix itself. tmux is now in `prefix` and the next press
            // is the one it will look up there.
            self.prefix_state = .after_prefix;
            self.repeat_deadline = null;
        } else if (self.repeat_keys.contains(spelled)) {
            // A `-r` binding. tmux holds the table open, and every repeat
            // re-arms it, so the deadline is set again here rather than only
            // on the first one.
            const window = if (self.prefix_state == .after_prefix and self.initial_repeat_ms != 0)
                self.initial_repeat_ms
            else
                self.repeat_ms;
            self.prefix_state = .repeating;
            const now: std.Io.Timestamp = .now(self.io, .awake);
            self.repeat_deadline = now.addDuration(.{
                .nanoseconds = @as(i96, window) * std.time.ns_per_ms,
            });
        } else {
            // Anything else ends the sequence, which is what tmux does with
            // a key bound without `-r` and with one bound to nothing at all.
            self.prefix_state = .none;
            self.repeat_deadline = null;
        }
        return true;
    }

    fn repeatLapsed(self: *Compositor) bool {
        const deadline = self.repeat_deadline orelse return true;
        const now: std.Io.Timestamp = .now(self.io, .awake);
        return deadline.durationTo(now).nanoseconds > 0;
    }

    pub fn sendKey(self: *Compositor, key: vaxis.Key, action: surface.Action) void {
        if (self.routeToTmux(key, action)) return;
        if (self.unsafe_lookup) {
            // The pattern this replaced: look the pane up, release the lock,
            // then use the pointer. The wait only makes a window that is
            // nanoseconds wide in normal operation long enough to observe.
            self.mutex.lockUncancelable(self.io);
            const pane = self.panes.get(self.focused);
            self.mutex.unlock(self.io);
            if (pane) |p| {
                self.io.sleep(.{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};
                self.noteIfDead(p);
                p.surface.sendKey(key, action);
            }
            return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.focusedPaneLocked()) |pane| {
            self.noteIfDead(pane);
            pane.surface.sendKey(key, action);
        }
    }

    /// Report a pane used past its lifetime. The sentinel is cleared before
    /// the free and the allocator poisons what it reclaims, so a stale
    /// pointer reads neither.
    fn noteIfDead(self: *Compositor, pane: *Pane) void {
        if (pane.magic == pane_alive) return;
        const path = self.uaf_log orelse return;
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "use-after-free: pane magic {x}\n", .{pane.magic}) catch return;
        if (std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false })) |file| {
            defer file.close(self.io);
            if (file.stat(self.io)) |st| {
                _ = file.writePositionalAll(self.io, line, st.size) catch {};
            } else |_| {}
        } else |_| {}
    }

    pub fn sendMouse(self: *Compositor, mouse: vaxis.Mouse, col: i16, row: i16) void {
        if (col < 0 or row < 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.paneAtLocked(@intCast(col), @intCast(row)) orelse return;
        if (mouse.type == .press) {
            self.focusLocked(pane.id) catch {};
            // And tell tmux, so a binding pressed after a click acts on the
            // pane that was clicked. Fire and forget, like every other
            // command on the key path; tmux confirms with
            // `%window-pane-changed`, which `apply` already handles.
            var buf: [64]u8 = undefined;
            if (control.Command.selectPaneBuf(&buf, pane.id)) |cmd| {
                self.stream.send(cmd) catch {};
            } else |_| {}
        }
        pane.surface.sendMouse(
            mouse,
            col - @as(i16, @intCast(pane.rect.x)),
            row - @as(i16, @intCast(pane.rect.y)),
        );
    }

    /// Draw every pane into `win`, with a border between neighbours. The rects
    /// are already in `win`'s coordinates because tmux tiled to the size we
    /// gave it.
    pub fn draw(self: *Compositor, win: vaxis.Window, images: surface.ImageSink) !void {
        // Held across the whole draw, not just the lookup. Copying the
        // pointers out and releasing first left the blit reading panes the
        // event worker had freed, and `focused` is a slice that the same
        // worker reallocates. Holding it only delays a layout change, which
        // happens when a pane appears or goes; the output path takes this
        // lock just long enough to find a pane and feeds outside it.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const panes = self.panes.values();
        var focus_rect: ?layout.PaneRect = null;
        for (panes) |pane| if (std.mem.eql(u8, pane.id, self.focused)) {
            focus_rect = pane.rect;
        };

        for (panes) |pane| {
            const r = pane.rect;
            if (r.x >= win.width or r.y >= win.height) continue;
            const child = win.child(.{
                .x_off = @intCast(r.x),
                .y_off = @intCast(r.y),
                .width = @intCast(@min(r.w, win.width - r.x)),
                .height = @intCast(@min(r.h, win.height - r.y)),
            });
            try pane.surface.draw(child, images);
            // tmux leaves one column and one row between panes for the
            // border; it is ours to draw because tmux draws it on its own
            // screen, which we never see.
            if (r.x + r.w < win.width) {
                const active = focus_rect != null and focus_rect.?.x == r.x and focus_rect.?.y == r.y;
                for (r.y..@min(r.y + r.h, win.height)) |y| win.writeCell(
                    @intCast(r.x + r.w),
                    @intCast(y),
                    border('\u{2502}', active),
                );
            }
            if (r.y + r.h < win.height) {
                const active = focus_rect != null and focus_rect.?.x == r.x and focus_rect.?.y == r.y;
                for (r.x..@min(r.x + r.w + 1, win.width)) |x| win.writeCell(
                    @intCast(x),
                    @intCast(r.y + r.h),
                    border('\u{2500}', active),
                );
            }
        }
    }

    fn border(comptime cp: u21, active: bool) vaxis.Cell {
        const bytes = comptime blk: {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            break :blk buf[0..n].*;
        };
        return .{
            .char = .{ .grapheme = &bytes, .width = 1 },
            .style = .{ .fg = .{ .index = if (active) 2 else 8 } },
        };
    }

    /// What the program in a pane reported about itself, for the sidebar.
    ///
    /// The lock is held across the read, as every other reader of a pane
    /// does: the event worker frees a pane that leaves the layout.
    pub fn reportedStatus(self: *Compositor, pane_id: []const u8) ?sidebar.Reported {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.panes.get(pane_id) orelse return null;
        const summary = pane.surface.statusSummary() orelse return null;
        var out: sidebar.Reported = .{
            .state = switch (summary.state) {
                .idle => .idle,
                .working => .working,
                .done => .done,
                .blocked => .blocked,
                .@"error" => .@"error",
            },
            .kind = if (summary.kind) |k| switch (k) {
                .permission => .permission,
                .question => .question,
                .auth => .auth,
            } else null,
            .progress = summary.progress,
        };
        // Both sides hold the title by value, so this is a copy of a copy
        // rather than a slice that outlives the lock above. Clamped rather
        // than assumed equal: the two buffers are the same size today and
        // nothing here should break if one of them grows.
        const t = summary.title();
        const n = @min(t.len, out.title_buf.len);
        @memcpy(out.title_buf[0..n], t[0..n]);
        out.title_len = @intCast(n);
        return out;
    }

    /// The sidebar's view of this compositor's reports.
    pub fn statusLookup(self: *Compositor) sidebar.Status {
        return .{ .ctx = self, .get = lookupStatus };
    }

    fn lookupStatus(ctx: ?*anyopaque, pane_id: []const u8) ?sidebar.Reported {
        const self: *Compositor = @ptrCast(@alignCast(ctx.?));
        return self.reportedStatus(pane_id);
    }

    /// The focused pane's cursor, in compositor coordinates.
    pub fn cursor(self: *Compositor) ?surface.Position {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.focusedPaneLocked() orelse return null;
        const c = pane.surface.cursor() orelse return null;
        return .{
            .col = @intCast(pane.rect.x + c.col),
            .row = @intCast(pane.rect.y + c.row),
        };
    }
};

test "a repeating binding is recognised in what list-keys prints" {
    // Real lines from `tmux list-keys -T prefix` on tmux 3.8. tmux pads the
    // output to align it, which is why this is tokenised rather than sliced.
    try std.testing.expectEqualStrings(
        "C-h",
        Compositor.repeatKeyOf("bind-key -r -T prefix C-h     resize-pane -L 1").?,
    );
    try std.testing.expectEqualStrings(
        "M-Up",
        Compositor.repeatKeyOf("bind-key -r -T prefix M-Up    resize-pane -U 5").?,
    );
    // Bound without -r, so it ends a prefix sequence rather than holding the
    // table open. Not knowing the difference is the whole bug this prevents.
    try std.testing.expect(Compositor.repeatKeyOf("bind-key    -T prefix z       resize-pane -Z") == null);
    try std.testing.expect(Compositor.repeatKeyOf("bind-key    -T prefix h       select-pane -L") == null);
    // A punctuation key is printed escaped, and that is the spelling tmm
    // sends, so it is also the spelling that has to be stored.
    try std.testing.expectEqualStrings(
        "\\;",
        Compositor.repeatKeyOf("bind-key -r -T prefix \\;      last-pane").?,
    );
    // Lines that are not a binding at all.
    try std.testing.expect(Compositor.repeatKeyOf("") == null);
    try std.testing.expect(Compositor.repeatKeyOf("something else entirely") == null);
    try std.testing.expect(Compositor.repeatKeyOf("bind-key -r") == null);
    try std.testing.expect(Compositor.repeatKeyOf("bind-key -r -T prefix") == null);
    // A table other than prefix still parses; the caller asked for one table.
    try std.testing.expectEqualStrings(
        "C-k",
        Compositor.repeatKeyOf("bind-key -r -T copy-mode C-k  send-keys -X cursor-up").?,
    );
}
