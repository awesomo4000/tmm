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

const Allocator = std.mem.Allocator;

/// One tmux pane: its id, where the layout puts it, and our terminal for it.
pub const Pane = struct {
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

    /// Apply a layout string: add panes that appeared, drop those that went,
    /// and resize the rest. Pane terminals are sized from the layout, never
    /// guessed, so they agree with what tmux told the process.
    fn applyLayout(self: *Compositor, window: []const u8, spec: []const u8) !void {
        const rects = try layout.parse(self.alloc, spec);
        defer self.alloc.free(rects);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!std.mem.eql(u8, self.window, window)) {
            if (self.window.len != 0) self.alloc.free(self.window);
            self.window = try self.alloc.dupe(u8, window);
        }

        var live: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer live.deinit(self.alloc);

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
            // Seed from tmux's own screen so a pane that existed before we
            // attached is not blank until it next writes. tmux models no
            // images, so anything drawn before the attach is text only.
            self.seed(pane) catch {};
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
            pane.surface.deinit();
            self.alloc.free(pane.id);
            self.alloc.destroy(pane);
        }
    }

    fn seed(self: *Compositor, pane: *Pane) !void {
        const reply = try self.stream.requestArgv(self.alloc, &.{
            "capture-pane", "-p", "-e", "-t", pane.id,
        });
        defer reply.deinit(self.alloc);
        if (!reply.ok) return;
        for (reply.lines, 0..) |line, n| {
            if (n != 0) pane.surface.feed("\r\n");
            pane.surface.feed(line);
        }
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
                // The visible layout is what this client sees, which is what
                // we are drawing; `layout` is the window's own.
                const spec = if (l.visible.len != 0) l.visible else l.layout;
                try self.applyLayout(l.window, spec);
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
        if (std.mem.eql(u8, self.focused, pane)) return;
        if (!self.panes.contains(pane)) return;
        if (self.focused.len != 0) self.alloc.free(self.focused);
        self.focused = try self.alloc.dupe(u8, pane);
    }

    /// The pane at a point, in compositor coordinates.
    pub fn paneAt(self: *Compositor, col: u16, row: u16) ?*Pane {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.panes.values()) |pane| {
            const r = pane.rect;
            if (col >= r.x and col < r.x + r.w and row >= r.y and row < r.y + r.h)
                return pane;
        }
        return null;
    }

    fn focusedPane(self: *Compositor) ?*Pane {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.panes.get(self.focused);
    }

    pub fn sendKey(self: *Compositor, key: vaxis.Key, action: surface.Action) void {
        if (self.focusedPane()) |pane| pane.surface.sendKey(key, action);
    }

    pub fn sendMouse(self: *Compositor, mouse: vaxis.Mouse, col: i16, row: i16) void {
        if (col < 0 or row < 0) return;
        const pane = self.paneAt(@intCast(col), @intCast(row)) orelse return;
        if (mouse.type == .press) self.focus(pane.id) catch {};
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
        self.mutex.lockUncancelable(self.io);
        const panes = try self.alloc.dupe(*Pane, self.panes.values());
        const focused = self.focused;
        var focus_rect: ?layout.PaneRect = null;
        for (panes) |pane| if (std.mem.eql(u8, pane.id, focused)) {
            focus_rect = pane.rect;
        };
        self.mutex.unlock(self.io);
        defer self.alloc.free(panes);

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

    /// The focused pane's cursor, in compositor coordinates.
    pub fn cursor(self: *Compositor) ?surface.Position {
        const pane = self.focusedPane() orelse return null;
        const c = pane.surface.cursor() orelse return null;
        return .{
            .col = @intCast(pane.rect.x + c.col),
            .row = @intCast(pane.rect.y + c.row),
        };
    }
};
