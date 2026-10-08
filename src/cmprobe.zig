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
const cmstream = @import("cmstream.zig");

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

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    const stream = try cmstream.Stream.open(gpa, io, .{
        .socket = socket,
        .label = label,
        .session = session,
    });
    defer stream.close();

    if (send_cmd) |cmd| {
        // Run it as a request/reply over this control client, so the probe also
        // exercises the no-subprocess query path.
        const reply = try stream.request(gpa, cmd);
        defer reply.deinit(gpa);
        try w.print("request\t{s}\t{d} lines\n", .{ if (reply.ok) "ok" else "error", reply.lines.len });
        for (reply.lines) |l| {
            try w.writeAll("reply\t");
            try writeSafe(w, l);
            try w.writeAll("\n");
        }
        try w.flush();
    }

    var seen: usize = 0;
    while (seen < max_events) {
        const ev = (try stream.next()) orelse break;
        seen += 1;
        if (raw_mode) {
            try w.print("RAW\t{s}\n", .{@tagName(ev)});
        } else {
            try printEvent(gpa, w, ev);
        }
        // Flush per event: a probe is watched live, and the harness kills the
        // tmux server to end the stream, so buffered output would be lost.
        try w.flush();
        if (ev == .exit) break;
    }
    try w.flush();
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
