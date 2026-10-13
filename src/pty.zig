// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! A pseudoterminal pair, and a child process attached to it as its
//! controlling terminal.
//!
//! `openpty` comes from libc: std has no wrapper, and the raw ioctl route
//! needs per-platform constants that std does not expose for darwin either.
//! libc is already required in practice (portability-report.md records Linux
//! builds failing without it for `getuid`).
//!
//! The child is started with fork and exec rather than `std.process.spawn`,
//! because between the two it has to call `setsid` and `TIOCSCTTY` to make the
//! pty its controlling terminal, and spawn has no hook for that. Without it:
//!
//!   - the shell reports "no job control in this shell", and
//!   - a later `TIOCSWINSZ` on the master delivers no SIGWINCH, so a resize
//!     never reaches the child. That is the one that matters here: a draggable
//!     divider is useless if the program on the other side never finds out.
//!
//! Only async-signal-safe calls happen between fork and exec, since the parent
//! is multithreaded by this point. Everything that allocates is done first.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*:0]u8,
    termios: ?*const anyopaque,
    winsize: ?*const anyopaque,
) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const darwin = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

/// `std.c.T` defines TIOCGWINSZ but not its neighbours on darwin, so the
/// darwin values are built the way std builds that one: an _IOW of
/// `struct winsize` in group 't' number 103, and a bare _IO number 97.
const TIOCSWINSZ: c_ulong = if (darwin)
    0x80000000 | ((@sizeOf(posix.winsize) & std.c.IOCPARM_MASK) << 16) |
        (@as(c_ulong, 't') << 8) | 103
else
    std.c.T.IOCSWINSZ;
const TIOCSCTTY: c_ulong = if (darwin)
    0x20000000 | (@as(c_ulong, 't') << 8) | 97
else
    std.c.T.IOCSCTTY;

pub const Pty = struct {
    master: std.Io.File,
    /// The child, which is a session leader, so signals go to its whole
    /// process group.
    pid: std.c.pid_t,
    reaped: bool = false,

    pub const Size = struct { cols: u16, rows: u16 };

    /// Open a pair and start `argv` on it, sized to `size`. The allocator is
    /// used only to build the NUL-terminated argv, before the fork, and is
    /// released before returning.
    pub fn spawn(alloc: Allocator, argv: []const []const u8, size: Size) !Pty {
        if (argv.len == 0) return error.EmptyArgv;

        // All allocation happens here, ahead of the fork.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const argv_z = try aa.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |arg, i| argv_z[i] = try aa.dupeZ(u8, arg);
        const file = argv_z[0].?;

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
        errdefer _ = close(master_fd);

        const pid = fork();
        if (pid < 0) {
            _ = close(slave_fd);
            return error.ForkFailed;
        }
        if (pid == 0) {
            // Child. Async-signal-safe calls only, and no way to report a
            // failure other than the exit status.
            _ = setsid();
            _ = ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0));
            _ = dup2(slave_fd, 0);
            _ = dup2(slave_fd, 1);
            _ = dup2(slave_fd, 2);
            if (slave_fd > 2) _ = close(slave_fd);
            _ = close(master_fd);
            _ = execvp(file, argv_z.ptr);
            std.c._exit(127);
        }

        // Parent. The slave is closed here on purpose: while it stays open the
        // master never reports end of stream, so the reader could not tell
        // that the child had exited.
        _ = close(slave_fd);

        // openpty leaves the master blocking, which is what the reader wants.
        return .{
            .master = .{ .handle = master_fd, .flags = .{ .nonblocking = false } },
            .pid = pid,
        };
    }

    /// Hang up the child's process group and reap it. Idempotent.
    pub fn deinit(self: *Pty, io: std.Io) void {
        if (self.reaped) return;
        self.reaped = true;
        // Negative pid addresses the process group, so a shell's children go
        // too. The child is a session leader, so its pid is its group id.
        _ = std.c.kill(-self.pid, .HUP);
        _ = std.c.kill(-self.pid, .KILL);
        _ = std.c.waitpid(self.pid, null, 0);
        self.master.close(io);
    }

    pub fn setSize(self: *const Pty, size: Size) !void {
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (ioctl(self.master.handle, TIOCSWINSZ, &ws) != 0)
            return error.SetSizeFailed;
    }

    /// Read available output. Returns 0 at end of stream.
    pub fn read(self: *const Pty, io: std.Io, buf: []u8) !usize {
        return self.master.readStreaming(io, &.{buf});
    }

    pub fn write(self: *const Pty, io: std.Io, bytes: []const u8) !void {
        try self.master.writeStreamingAll(io, bytes);
    }
};
