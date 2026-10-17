// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! One terminal region: a pty with a child process on it, and a `Surface`
//! parsing its output and encoding input back to it.
//!
//! This is the right-hand side of `tmm --shell`: an ordinary shell, in which
//! an ordinary `tmux attach` works. It is not a tmux pane and tmm is not a
//! terminal multiplexer here; the split is tmm drawing two things into one
//! window, so the sidebar costs no second OS window and no second click.
//!
//! Everything about being a terminal lives in `surface.zig`, which the
//! compositor shares. What is left here is the pty: spawning it, sizing it,
//! and closing it exactly once.
//!
//! `Region` must not move once `create` returns, because `Surface` must not.

const std = @import("std");
const vaxis = @import("vaxis");
const Pty = @import("pty.zig").Pty;
const surface = @import("surface.zig");

const Allocator = std.mem.Allocator;

pub const Region = struct {
    io: std.Io,
    alloc: Allocator,
    pty: Pty,
    surface: surface.Surface,

    /// Set once the child's pty reaches end of stream.
    exited: std.atomic.Value(bool) = .init(false),

    /// False once the pty has been closed. Closing it is what ends the
    /// reader task's blocking read, so shutdown closes before it joins and
    /// `destroy` must not close a second time.
    pty_open: bool = true,

    /// The display's cell size in pixels, zero until the outer terminal
    /// reports one. Kept so a resize can recompute the pty pixel size.
    cell_width: u32 = 0,
    cell_height: u32 = 0,

    pub fn create(
        alloc: Allocator,
        io: std.Io,
        argv: []const []const u8,
        cols: u16,
        rows: u16,
        input_log: ?[]const u8,
    ) !*Region {
        const self = try alloc.create(Region);
        errdefer alloc.destroy(self);

        self.* = .{
            .io = io,
            .alloc = alloc,
            .pty = try .spawn(alloc, argv, .{ .cols = cols, .rows = rows }),
            .surface = undefined,
        };
        errdefer self.pty.deinit(io);

        try self.surface.init(io, alloc, cols, rows, .{
            .ctx = self,
            .write = writePty,
        }, input_log);
        return self;
    }

    pub fn closePty(self: *Region) void {
        if (!self.pty_open) return;
        self.pty_open = false;
        self.pty.deinit(self.io);
    }

    pub fn destroy(self: *Region) void {
        const alloc = self.alloc;
        self.closePty();
        self.surface.deinit();
        alloc.destroy(self);
    }

    /// The surface's sink. Dropping writes after the pty is closed is what
    /// keeps a late terminal response from touching a dead descriptor.
    fn writePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Region = @ptrCast(@alignCast(ctx.?));
        if (!self.pty_open) return;
        self.pty.write(self.io, bytes) catch {};
    }

    /// Parse `bytes` as output from the child. Called from the reader task.
    pub fn feed(self: *Region, bytes: []const u8) void {
        self.surface.feed(bytes);
    }

    /// Resize the terminal, the pty, and so the child's idea of its window.
    pub fn resize(self: *Region, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0 or !self.pty_open) return;
        if (cols == self.surface.cols and rows == self.surface.rows) return;
        try self.surface.resize(cols, rows);
        try self.pty.setSize(self.ptySize(cols, rows));
    }

    /// Tell the region how big a cell is in the terminal it is shown in, which
    /// is the only way it can know: a cell size is a property of the display,
    /// not of the pty. Both routes a program might take are then answered --
    /// the ioctl, through the pty window size, and the `CSI 14/16/18 t`
    /// queries, through the surface -- because viewers disagree about which to
    /// use and `kitty icat` only consults the ioctl.
    pub fn setCellSize(self: *Region, width: u32, height: u32) void {
        self.surface.setCellSize(width, height);
        self.cell_width = width;
        self.cell_height = height;
        if (!self.pty_open) return;
        self.pty.setSize(self.ptySize(self.surface.cols, self.surface.rows)) catch {};
    }

    /// The pty window size, carrying pixels only when a cell size is known.
    /// Multiplied in u32 and clamped, because `struct winsize` counts pixels
    /// in a u16 and a wide enough region at a large enough font overflows it.
    fn ptySize(self: *const Region, cols: u16, rows: u16) Pty.Size {
        const w = std.math.cast(u16, @as(u32, cols) * self.cell_width) orelse 0;
        const h = std.math.cast(u16, @as(u32, rows) * self.cell_height) orelse 0;
        return .{ .cols = cols, .rows = rows, .xpixel = w, .ypixel = h };
    }

    pub fn sendKey(self: *Region, key: vaxis.Key, action: surface.Action) void {
        if (!self.pty_open) return;
        self.surface.sendKey(key, action);
    }

    pub fn sendMouse(self: *Region, mouse: vaxis.Mouse, col: i16, row: i16) void {
        if (!self.pty_open) return;
        self.surface.sendMouse(mouse, col, row);
    }

    pub fn draw(self: *Region, win: vaxis.Window, images: surface.ImageSink) !void {
        return self.surface.draw(win, images);
    }

    pub fn cursor(self: *Region) ?surface.Position {
        return self.surface.cursor();
    }
};
