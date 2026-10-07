// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Control-mode transport: owns a long-lived `tmux -C attach` child and turns
//! its stdout into a stream of `control.Event`. The parsing is in control.zig;
//! this is only the process and line plumbing.
//!
//! Lifetime: events borrow from an internal line buffer and are valid until the
//! next `next()` call, exactly like `control.Parser.feed`. Copy what you keep.
//!
//! Three Zig 0.16 traps are handled here so callers do not meet them again:
//!   - `takeDelimiterInclusive`, not `Exclusive`: the Exclusive variant tosses
//!     only the returned length and leaves the delimiter buffered, so the next
//!     call returns a zero-length slice and tosses nothing. With an empty-line
//!     skip that is a silent infinite spin that looks like a blocked read.
//!   - `readerStreaming`, not `reader`: a child's stdout is a pipe, and
//!     `reader` defaults to positional reads.
//!   - `Child.kill` reaps the child and clears `child.id`, so `wait` must not
//!     follow it.

const std = @import("std");
const control = @import("control.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Socket path (`-S`). Mutually exclusive with `label`.
    socket: ?[]const u8 = null,
    /// Socket name (`-L`). Mutually exclusive with `socket`.
    label: ?[]const u8 = null,
    /// Session to attach to; null attaches to the most recent.
    session: ?[]const u8 = null,
    /// tmux binary, overridable for tests.
    tmux_bin: []const u8 = "tmux",
    /// Line buffer. Must exceed the longest expected line; %output blocks are
    /// bounded by tmux's own write size, but a wide pane redraw can be large.
    buffer_bytes: usize = 256 * 1024,
};

pub const Stream = struct {
    alloc: Allocator,
    io: std.Io,
    child: std.process.Child,
    reader: std.Io.File.Reader,
    buffer: []u8,
    parser: control.Parser = .{},
    /// Set once the child has reported `%exit` or closed its stdout.
    ended: bool = false,

    /// Spawn the control-mode client. Heap-allocated because `reader` holds a
    /// self-referential interface; returning it by value would move it.
    pub fn open(alloc: Allocator, io: std.Io, opts: Options) !*Stream {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.append(alloc, opts.tmux_bin);
        if (opts.socket) |s| {
            try argv.append(alloc, "-S");
            try argv.append(alloc, s);
        } else if (opts.label) |l| {
            try argv.append(alloc, "-L");
            try argv.append(alloc, l);
        }
        try argv.append(alloc, "-C");
        try argv.append(alloc, "attach");
        if (opts.session) |s| {
            try argv.append(alloc, "-t");
            try argv.append(alloc, s);
        }

        const buffer = try alloc.alloc(u8, opts.buffer_bytes);
        errdefer alloc.free(buffer);

        const self = try alloc.create(Stream);
        errdefer alloc.destroy(self);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .child = child,
            .buffer = buffer,
            .reader = undefined,
        };
        self.reader = self.child.stdout.?.readerStreaming(io, self.buffer);
        return self;
    }

    pub fn close(self: *Stream) void {
        // kill() reaps and clears child.id; never call wait() after it.
        self.child.kill(self.io);
        self.alloc.free(self.buffer);
        self.alloc.destroy(self);
    }

    /// Next event, or null once the stream has ended. Borrows until the next call.
    pub fn next(self: *Stream) !?control.Event {
        if (self.ended) return null;
        while (true) {
            const raw = self.reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    self.ended = true;
                    return null;
                },
                else => return err,
            };
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            if (line.len == 0) continue;
            const ev = self.parser.feed(line);
            if (ev == .exit) self.ended = true;
            return ev;
        }
    }

    /// Write a tmux command for the control client to run. The reply arrives as
    /// a guard block (`reply_begin` .. `reply_end`) in the event stream.
    pub fn send(self: *Stream, command: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var w = self.child.stdin.?.writer(self.io, &buf);
        try w.interface.writeAll(command);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }
};
