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

    input_log: ?[]const u8 = null,

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
            "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}",
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
            try rects.append(self.alloc, .{ .id = id, .x = x, .y = y, .w = w, .h = h });
        }
        if (rects.items.len == 0) return;
        try self.applyRects(window, rects.items);
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
    fn seed(self: *Compositor, pane: *Pane) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, self.opts.tmux_bin);
        if (self.opts.socket) |socket| {
            try argv.append(self.alloc, "-S");
            try argv.append(self.alloc, socket);
        } else if (self.opts.label) |label| {
            try argv.append(self.alloc, "-L");
            try argv.append(self.alloc, label);
        }
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

    pub fn sendKey(self: *Compositor, key: vaxis.Key, action: surface.Action) void {
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
        if (mouse.type == .press) self.focusLocked(pane.id) catch {};
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
        return .{
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
