// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! A timestamping endpoint for latency measurement: it reads its stdin and
//! records when each byte arrived, as exactly as the machine can say. With
//! `--send` it is the other end instead, writing keys to a descriptor and
//! recording when each one left.
//!
//! Both ends matter. With a Python sender, the reading is taken and then the
//! interpreter calls `write`; anything that happens in between -- a
//! deschedule, a garbage collection -- lands in the number and reads as
//! latency in the thing being measured. Running both ends here leaves no
//! interpreter in the timed path at all: the harness only sets up the pty
//! and compares the two logs afterwards.
//!
//! It exists because the measurement harness used to be Python on both ends,
//! which put the noise floor (one to five milliseconds of interpreter and
//! scheduler jitter) *above* the thing being measured (a tenth of a
//! millisecond). An instrument has to be quicker than its subject, or a
//! worst case cannot be told from a hiccup in the instrument.
//!
//! The rules that make it trustworthy:
//!
//!   * The clock is `clock_gettime(CLOCK_MONOTONIC)` and nothing else, so
//!     that a reading here is directly comparable with one taken by the
//!     harness. Python's `time.monotonic()` is a different clock on macOS
//!     (mach_absolute_time), which is why the harness is made to ask for
//!     this one by name. `--clock` prints a reading and exits, which is how
//!     that agreement is checked rather than assumed.
//!   * The timestamp is taken on the line after `read` returns, before
//!     anything is decoded, counted or written. `--overhead` reports what
//!     that costs.
//!   * Records go to a fixed array and are written out at exit. A file
//!     write between two keystrokes would be measured as latency on the
//!     next one.
//!   * `--load` blasts the screen the way a program repainting itself does,
//!     and never blocks on it: stdout is nonblocking, a partial write is
//!     finished rather than abandoned, and a frame is dropped rather than
//!     waited for. Load that waits is not load.

const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
});

/// One arrival: when, and what came in.
const Record = struct {
    at_ns: u64,
    bytes: [8]u8,
    len: u8,
};

const capacity = 4096;
var records: [capacity]Record = undefined;
var count: usize = 0;

/// The one clock this program uses. Nanoseconds, monotonic, and the same
/// source the harness is told to read, so the two can be subtracted.
///
/// `CLOCK_MONOTONIC_RAW` rather than `CLOCK_MONOTONIC`: the plain one ticks
/// at a microsecond on macOS, and 97 percent of back-to-back readings come
/// back identical, which is a poor ruler for something that takes a tenth of
/// a millisecond. The raw clock ticks at 41ns here, the machine's timebase,
/// and exists on Linux too, which `CLOCK_UPTIME_RAW` does not.
fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC_RAW, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn usage(io: std.Io) noreturn {
    const text =
        \\keyprobe - timestamp each byte arriving on stdin
        \\
        \\  --log PATH    where to write the records (default stdout at exit)
        \\  --load        blast the screen while reading, as a program repainting does
        \\  --quit BYTE   stop when this character arrives (default Q)
        \\  --clock       print one CLOCK_MONOTONIC reading in nanoseconds and exit
        \\  --overhead    report the cost of taking a timestamp and exit
        \\
        \\ as the sender:
        \\  --send        write keys to --fd and record when each one left
        \\  --fd N        the descriptor to write to and drain (default 3)
        \\  --keys N      how many keys to send (default 100)
        \\  --gap-us N    microseconds between keys (default 20000)
        \\
    ;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

/// What a timestamp costs, so the measurement can be read with that in mind.
fn overhead(io: std.Io) void {
    var samples: [10000]u64 = undefined;
    for (&samples) |*s| {
        const a = now();
        const b = now();
        s.* = b - a;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (samples) |s| total += s;
    var text: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&text,
        "clock_gettime(CLOCK_MONOTONIC_RAW) pair: min {d}ns median {d}ns p99 {d}ns max {d}ns mean {d}ns\n",
        .{ samples[0], samples[samples.len / 2], samples[samples.len * 99 / 100], samples[samples.len - 1], total / samples.len },
    ) catch return;
    var buf: [320]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(line) catch {};
    w.interface.flush() catch {};
}

/// Send `keys` bytes to `fd`, recording when each write happened, and drain
/// whatever comes back so the far side is never blocked on us.
///
/// The clock is read immediately before the write and nothing happens in
/// between. Draining is done in the gap that follows, never between the
/// reading and the write.
fn sendKeys(fd: c_int, keys: usize, gap_us: u64) void {
    // `Q` is the receiver's stop byte, so it is not in the alphabet: a key
    // stream containing it would end the measurement halfway through.
    const alphabet = "abcdefghijklmnoprstuvwxyz0123456789";
    var discard: [4096]u8 = undefined;
    var fds = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};

    for (0..keys) |i| {
        const byte = alphabet[i % alphabet.len];
        const at = now();
        _ = c.write(fd, &byte, 1);
        if (count < capacity) {
            records[count] = .{ .at_ns = at, .bytes = undefined, .len = 1 };
            records[count].bytes[0] = byte;
            count += 1;
        }
        // Wait out the gap, draining as we go.
        const until = at + gap_us * std.time.ns_per_us;
        while (now() < until) {
            if (c.poll(&fds, 1, 1) > 0) {
                if (c.read(fd, &discard, discard.len) <= 0) break;
            }
        }
    }
    // Stop the receiver so it writes its own records out.
    const stop: u8 = 'Q';
    _ = c.write(fd, &stop, 1);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    var log_path: ?[]const u8 = null;
    var load = false;
    var quit_byte: u8 = 'Q';
    var send = false;
    var send_fd: c_int = 3;
    var key_count: usize = 100;
    var gap_us: u64 = 20_000;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--log")) {
            log_path = args.next() orelse usage(init.io);
        } else if (std.mem.eql(u8, arg, "--load")) {
            load = true;
        } else if (std.mem.eql(u8, arg, "--send")) {
            send = true;
        } else if (std.mem.eql(u8, arg, "--fd")) {
            send_fd = std.fmt.parseInt(c_int, args.next() orelse usage(init.io), 10) catch usage(init.io);
        } else if (std.mem.eql(u8, arg, "--keys")) {
            key_count = std.fmt.parseInt(usize, args.next() orelse usage(init.io), 10) catch usage(init.io);
        } else if (std.mem.eql(u8, arg, "--gap-us")) {
            gap_us = std.fmt.parseInt(u64, args.next() orelse usage(init.io), 10) catch usage(init.io);
        } else if (std.mem.eql(u8, arg, "--quit")) {
            const v = args.next() orelse usage(init.io);
            if (v.len != 1) usage(init.io);
            quit_byte = v[0];
        } else if (std.mem.eql(u8, arg, "--clock")) {
            var text: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&text, "{d}\n", .{now()}) catch return;
            var buf: [64]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &buf);
            try w.interface.writeAll(line);
            try w.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--overhead")) {
            overhead(init.io);
            return;
        } else usage(init.io);
    }

    if (send) {
        sendKeys(send_fd, key_count, gap_us);
        try writeRecords(init.io, log_path);
        return;
    }

    // Raw mode, so a byte is delivered the moment it arrives rather than at
    // the end of a line. VMIN=1/VTIME=0: block until there is at least one
    // byte, which is what makes a read return as early as possible.
    var saved: c.struct_termios = undefined;
    const tty = c.tcgetattr(0, &saved) == 0;
    if (tty) {
        var raw = saved;
        c.cfmakeraw(&raw);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        _ = c.tcsetattr(0, c.TCSANOW, &raw);
    }
    defer if (tty) {
        _ = c.tcsetattr(0, c.TCSANOW, &saved);
    };

    if (load) _ = c.fcntl(1, c.F_SETFL, c.fcntl(1, c.F_GETFL, @as(c_int, 0)) | c.O_NONBLOCK);

    // One screen of output per frame, built once. Writing it is the load.
    var frame: [64 * 1024]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'x';
    var pending: []const u8 = &.{};

    var buf: [4096]u8 = undefined;
    var fds = [_]c.struct_pollfd{.{ .fd = 0, .events = c.POLLIN, .revents = 0 }};
    while (true) {
        // Under load the read must not block, or there would be no load
        // between keys. Without load, block: a poll loop would spin.
        var ready = true;
        if (load) {
            ready = c.poll(&fds, 1, 0) > 0;
        }
        if (ready) {
            const n = c.read(0, &buf, buf.len);
            // Nothing between the read and the clock.
            const at = now();
            if (n <= 0) break;
            const got = buf[0..@intCast(n)];
            if (count < capacity) {
                var rec: Record = .{ .at_ns = at, .bytes = undefined, .len = @intCast(@min(got.len, 8)) };
                @memcpy(rec.bytes[0..rec.len], got[0..rec.len]);
                records[count] = rec;
                count += 1;
            }
            if (std.mem.indexOfScalar(u8, got, quit_byte) != null) break;
        }
        if (load) {
            // Finish whatever is half-written before offering anything new:
            // abandoning part of a write puts a torn escape sequence on the
            // wire. A whole frame is dropped instead.
            if (pending.len == 0) pending = &frame;
            const w = c.write(1, pending.ptr, pending.len);
            if (w > 0) pending = pending[@intCast(w)..] else pending = &.{};
        }
    }

    try writeRecords(init.io, log_path);
}

/// Write the records out. Only ever at the end: a write between two
/// keystrokes would land in the next measurement.
fn writeRecords(io: std.Io, log_path: ?[]const u8) !void {
    var out: [capacity * 48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    for (records[0..count]) |rec| {
        w.print("{d} {x}\n", .{ rec.at_ns, rec.bytes[0..rec.len] }) catch break;
    }
    const text = w.buffered();
    if (log_path) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        _ = try file.writePositionalAll(io, text, 0);
    } else {
        var obuf: [4096]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(io, &obuf);
        try out_writer.interface.writeAll(text);
        try out_writer.interface.flush();
    }
}
