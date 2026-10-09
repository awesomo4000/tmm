// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! A pseudoterminal pair, and a child process attached to it.
//!
//! `openpty` comes from libc: std has no wrapper, and the raw ioctl route needs
//! per-platform constants that std does not expose for darwin either. libc is
//! already required in practice (portability-report.md records Linux builds
//! failing without it for `getuid`).
//!
//! The child receives the slave as all three standard streams, so `isatty` is
//! true and a shell starts interactively. It is deliberately *not* made a
//! session leader with a controlling terminal, which would need fork, setsid
//! and TIOCSCTTY rather than `std.process.spawn`. The visible cost is job
//! control: a shell may report "no job control in this shell". Interactive use,
//! and running tmux inside, both work.

const std = @import("std");
const posix = std.posix;

extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*:0]u8,
    termios: ?*const anyopaque,
    winsize: ?*const anyopaque,
) c_int;

pub const Pty = struct {
    master: std.Io.File,
    slave: std.Io.File,
    child: std.process.Child,

    pub const Size = struct { cols: u16, rows: u16 };

    /// Open a pair and start `argv` on it, sized to `size`.
    pub fn spawn(io: std.Io, argv: []const []const u8, size: Size) !Pty {
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (openpty(&master_fd, &slave_fd, null, null, &ws) != 0)
            return error.OpenPtyFailed;

        // openpty leaves both ends blocking.
        const master: std.Io.File = .{ .handle = master_fd, .flags = .{ .nonblocking = false } };
        const slave: std.Io.File = .{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
        errdefer master.close(io);
        errdefer slave.close(io);

        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .{ .file = slave },
            .stdout = .{ .file = slave },
            .stderr = .{ .file = slave },
        });
        return .{ .master = master, .slave = slave, .child = child };
    }

    pub fn deinit(self: *Pty, io: std.Io) void {
        // kill() reaps and clears child.id; never wait() after it.
        self.child.kill(io);
        self.slave.close(io);
        self.master.close(io);
    }

    pub fn setSize(self: *const Pty, size: Size) !void {
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (posix.system.ioctl(self.master.handle, posix.T.IOCSWINSZ, @intFromPtr(&ws)) != 0)
            return error.SetSizeFailed;
    }

    /// Read available output. Returns 0 at end of stream.
    pub fn read(self: *const Pty, io: std.Io, buf: []u8) !usize {
        return self.master.readStreaming(io, &.{buf});
    }

    pub fn write(self: *const Pty, io: std.Io, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            offset += try self.master.writeStreaming(io, &.{bytes[offset..]});
        }
    }
};
