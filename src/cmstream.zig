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
    /// The line backing the most recently returned event, for deferring it.
    last_line: []const u8 = "",
    /// Notification lines seen while a command reply was outstanding.
    pending: std.ArrayList([]const u8) = .empty,
    /// Backing store for a deferred line being replayed through the parser.
    held: []u8,

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
        const held = try alloc.alloc(u8, opts.buffer_bytes);
        errdefer alloc.free(held);

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
            .held = held,
            .reader = undefined,
        };
        self.reader = self.child.stdout.?.readerStreaming(io, self.buffer);

        // tmux emits a guard block for the attach itself before any command of
        // ours. Guard blocks arrive in command order, so that block must be
        // consumed here or the first request() would match it instead of its own
        // reply and return the wrong result. Notifications seen while draining
        // it are deferred, not dropped.
        while (true) {
            const ev = (self.nextRaw() catch break) orelse break;
            if (ev == .reply_end) break;
            if (ev == .reply_begin or ev == .reply_line) continue;
            self.defer_line() catch {};
        }
        return self;
    }

    pub fn close(self: *Stream) void {
        // kill() reaps and clears child.id; never call wait() after it.
        self.child.kill(self.io);
        for (self.pending.items) |l| self.alloc.free(l);
        self.pending.deinit(self.alloc);
        self.alloc.free(self.held);
        self.alloc.free(self.buffer);
        self.alloc.destroy(self);
    }

    /// Next event, or null once the stream has ended. Borrows until the next call.
    ///
    /// Deferred notifications (collected while a `request` reply was in flight)
    /// are reported before anything new is read.
    pub fn next(self: *Stream) !?control.Event {
        if (self.pending.items.len > 0) {
            const line = self.pending.orderedRemove(0);
            defer self.alloc.free(line);
            // Notifications do not change guard depth, so re-feeding one here
            // cannot desynchronise the parser.
            @memcpy(self.held[0..line.len], line);
            self.last_line = self.held[0..line.len];
            return self.parser.feed(self.last_line);
        }
        return self.nextRaw();
    }

    /// Read and parse one line straight from the child, with no pending drain.
    fn nextRaw(self: *Stream) !?control.Event {
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
            self.last_line = line;
            const ev = self.parser.feed(line);
            if (ev == .exit) self.ended = true;
            return ev;
        }
    }

    /// Run a tmux command over this control client and return its reply lines.
    ///
    /// This is the alternative to spawning `tmux` per query: one long-lived
    /// client instead of a fork/exec per command. Notifications that arrive
    /// while the reply is outstanding are kept and handed back by later `next()`
    /// calls, so using this never loses events.
    ///
    /// Replies are matched by arrival order, which is why `open` drains the
    /// attach guard block first. Do not call this concurrently with itself.
    ///
    /// Caller owns the returned slice and its lines.
    pub fn request(self: *Stream, alloc: Allocator, command: []const u8) !Reply {
        try self.send(command);

        var lines: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (lines.items) |l| alloc.free(l);
            lines.deinit(alloc);
        }
        var ok = true;
        var saw_begin = false;

        while (true) {
            const ev = (try self.nextRaw()) orelse return error.StreamEnded;
            switch (ev) {
                .reply_begin => saw_begin = true,
                .reply_line => |l| if (saw_begin) {
                    const copy = try alloc.dupe(u8, l);
                    errdefer alloc.free(copy);
                    try lines.append(alloc, copy);
                },
                .reply_end => |r| {
                    ok = r.ok;
                    break;
                },
                // A notification interleaved with our reply. Keep the line so a
                // later next() still reports it.
                else => try self.defer_line(),
            }
        }
        return .{ .ok = ok, .lines = try lines.toOwnedSlice(alloc) };
    }

    pub const Reply = struct {
        ok: bool,
        lines: []const []const u8,
        pub fn deinit(self: Reply, alloc: Allocator) void {
            for (self.lines) |l| alloc.free(l);
            alloc.free(self.lines);
        }
    };

    /// Stash the line just parsed so a later `next()` reports it. Called when a
    /// notification shows up while a command reply is outstanding.
    fn defer_line(self: *Stream) !void {
        const copy = try self.alloc.dupe(u8, self.last_line);
        errdefer self.alloc.free(copy);
        try self.pending.append(self.alloc, copy);
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
