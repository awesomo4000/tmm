// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Development probe: run a real `tmux -C attach` and print every control-mode
//! event as control.zig classifies it. This exists to validate the parser and
//! the event dispatch against live tmux before backend.zig is restructured
//! around the control-mode stream.
//!
//!   cmprobe -S <socket> -t <session> [--cmd <tmux command>] [--events N]
//!
//! One line per event on stdout: `<tag>\t<fields...>`. %output payloads are
//! printed decoded and escaped back to a single safe line, so the harness can
//! assert on exact bytes. Exits on %exit, EOF, or after --events events; the
//! usual way to end a run is to kill the tmux server, which sends %exit.

const std = @import("std");
const control = @import("control.zig");

const usage =
    \\cmprobe -S <socket> -t <session> [--cmd <tmux command>] [--events N]
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var socket: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var send_cmd: ?[]const u8 = null;
    var raw_mode = false;
    var bytes_mode = false;
    var max_events: usize = 64;

    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-S")) {
            socket = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "-L")) {
            label = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "-t")) {
            session = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--bytes")) {
            bytes_mode = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            raw_mode = true;
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            send_cmd = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--events")) {
            const v = args.next() orelse return error.MissingValue;
            max_events = try std.fmt.parseInt(usize, v, 10);
        } else {
            var buf: [256]u8 = undefined;
            var err = std.Io.File.stderr().writer(io, &buf);
            try err.interface.writeAll(usage);
            try err.interface.flush();
            return error.BadUsage;
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "tmux");
    if (socket) |s| {
        try argv.append(gpa, "-S");
        try argv.append(gpa, s);
    } else if (label) |l| {
        try argv.append(gpa, "-L");
        try argv.append(gpa, l);
    }
    try argv.append(gpa, "-C");
    try argv.append(gpa, "attach");
    if (session) |s| {
        try argv.append(gpa, "-t");
        try argv.append(gpa, s);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    if (send_cmd) |cmd| {
        var in_buf: [512]u8 = undefined;
        var in = child.stdin.?.writer(io, &in_buf);
        try in.interface.writeAll(cmd);
        try in.interface.writeAll("\n");
        try in.interface.flush();
    }

    if (bytes_mode) {
        // Diagnostic: read straight off the fd, no Reader abstraction, and show
        // exactly what arrives and in how many reads.
        var buf: [4096]u8 = undefined;
        var reads: usize = 0;
        while (reads < 5) {
            const n = child.stdout.?.readStreaming(io, &.{buf[0..]}) catch |e| {
                try w.print("READ-ERR\t{s}\n", .{@errorName(e)});
                break;
            };
            reads += 1;
            if (n == 0) {
                try w.writeAll("EOF\n");
                break;
            }
            try w.print("READ[{d}] {d} bytes\t", .{ reads, n });
            try writeSafe(w, buf[0..n]);
            try w.writeAll("\n");
            try w.flush();
        }
        try w.flush();
        child.kill(io);
        return;
    }

    var read_buf: [64 * 1024]u8 = undefined;
    // readerStreaming, NOT reader: reader() defaults to positional reads, which
    // on a pipe yields the first line and then stalls forever. A control-mode
    // child is a pipe, so it must be read in streaming mode.
    var reader = child.stdout.?.readerStreaming(io, &read_buf);
    var parser: control.Parser = .{};
    var seen: usize = 0;

    while (seen < max_events) {
        // takeDelimiterInclusive, NOT Exclusive: the Exclusive variant tosses
        // only the returned length, leaving the newline in the buffer, so the
        // next call sees a leading delimiter, returns a zero-length slice and
        // tosses nothing. Combined with skipping empty lines that is a silent
        // infinite spin, not a blocked read.
        const raw = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;
        seen += 1;
        if (raw_mode) {
            try w.print("RAW\t{s}\n", .{line});
            try w.flush();
            continue;
        }
        const ev = parser.feed(line);
        try printEvent(gpa, w, ev);
        // Flush per event: a probe is watched live, and the harness kills the
        // tmux server to end the stream, so buffered output would be lost.
        try w.flush();
        if (ev == .exit) break;
    }
    try w.flush();

    // kill() reaps the child and clears child.id, so wait() must not follow it.
    child.kill(io);
}

fn printEvent(gpa: std.mem.Allocator, w: *std.Io.Writer, ev: control.Event) !void {
    switch (ev) {
        .output => |o| {
            const raw = try control.decodeAlloc(gpa, o.escaped);
            defer gpa.free(raw);
            try w.print("output\t{s}\t", .{o.pane});
            try writeSafe(w, raw);
            try w.writeAll("\n");
        },
        .extended_output => |o| {
            const raw = try control.decodeAlloc(gpa, o.escaped);
            defer gpa.free(raw);
            try w.print("extended_output\t{s}\t{s}\t", .{ o.pane, o.age });
            try writeSafe(w, raw);
            try w.writeAll("\n");
        },
        .layout_change => |l| try w.print(
            "layout_change\t{s}\t{s}\n",
            .{ l.window, l.layout },
        ),
        .window_add => |id| try w.print("window_add\t{s}\n", .{id}),
        .window_close => |id| try w.print("window_close\t{s}\n", .{id}),
        .window_renamed => |x| try w.print("window_renamed\t{s}\t{s}\n", .{ x.window, x.name }),
        .window_pane_changed => |x| try w.print("window_pane_changed\t{s}\t{s}\n", .{ x.window, x.pane }),
        .session_changed => |x| try w.print("session_changed\t{s}\t{s}\n", .{ x.session, x.name }),
        .session_window_changed => |x| try w.print("session_window_changed\t{s}\t{s}\n", .{ x.session, x.window }),
        .sessions_changed => try w.writeAll("sessions_changed\n"),
        .exit => try w.writeAll("exit\n"),
        .reply_begin => |r| try w.print("reply_begin\t{s}\n", .{r.num}),
        .reply_end => |r| try w.print("reply_end\t{s}\t{s}\n", .{ r.num, if (r.ok) "ok" else "error" }),
        .reply_line => |l| {
            try w.writeAll("reply_line\t");
            try writeSafe(w, l);
            try w.writeAll("\n");
        },
        else => try w.print("{s}\n", .{@tagName(ev)}),
    }
}

/// Render bytes on one line: printable ASCII verbatim, everything else \xNN.
fn writeSafe(w: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| {
        if (b >= 0x20 and b < 0x7f and b != '\\') {
            try w.writeByte(b);
        } else {
            try w.print("\\x{x:0>2}", .{b});
        }
    }
}
