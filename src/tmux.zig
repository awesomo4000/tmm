// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Which tmux server, and running one command against it as a subprocess.
//! Everything that talks to tmux builds its command line here, so the socket
//! flags are spelled in one place. The control-mode client is the other way
//! tmm talks to tmux, in cmstream.zig; it starts with the same command line.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// What answers as tmux, which changes how tmm talks to it.
pub const Kind = enum {
    tmux,
    /// psmux, a tmux for Windows. It runs one server per session, behind a
    /// command line that answers for all of them, so a control client hears
    /// only the session it attached to, and pane ids repeat across sessions.
    /// Its formats have no `#{n:}` modifier.
    psmux,
};

/// A tmux server: the default one when both socket fields are null.
pub const ServerOptions = struct {
    /// `-L`: a socket name in tmux's socket directory.
    socket_name: ?[]const u8 = null,
    /// `-S`: a socket path. Takes the place of `socket_name` when both are set.
    socket_path: ?[]const u8 = null,
    /// The tmux binary; null finds `default_bin` on PATH when it is run.
    tmux_bin: ?[]const u8 = null,
    /// What the binary is; see `Server.kind`.
    kind: Kind = .tmux,
    /// The environment tmux runs with; null inherits tmm's own. Borrowed.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// The tmux on Windows is psmux, which installs no `tmux` by default.
pub const default_bin = if (builtin.os.tag == .windows) "psmux" else "tmux";

/// Output beyond this is an error rather than an unbounded allocation.
const output_limit = 10 * 1024 * 1024;

/// `tmux`, its socket flags, then `args`. The slice is owned by the caller;
/// the strings in it are borrowed.
pub fn argv(a: Allocator, opts: ServerOptions, args: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.ensureTotalCapacity(a, 3 + args.len);
    list.appendAssumeCapacity(opts.tmux_bin orelse default_bin);
    if (opts.socket_path) |path| {
        list.appendSliceAssumeCapacity(&.{ "-S", path });
    } else if (opts.socket_name) |name| {
        list.appendSliceAssumeCapacity(&.{ "-L", name });
    }
    list.appendSliceAssumeCapacity(args);
    return list.toOwnedSlice(a);
}

pub const Result = struct {
    allocator: Allocator,
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn success(self: Result) bool {
        return self.exit_code == 0;
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    options: ServerOptions,
    /// The environment tmux runs with; null inherits tmm's own.
    environ_map: ?*const std.process.Environ.Map = null,

    pub fn init(allocator: Allocator, io: std.Io, options: ServerOptions) Server {
        return .{ .allocator = allocator, .io = io, .options = options, .environ_map = options.environ_map };
    }

    /// Run one command and wait for it. A command tmux ran and refused is a
    /// result, with its exit code and stderr; only failing to run tmux at
    /// all, or tmux dying, is an error.
    pub fn exec(self: *Server, args: []const []const u8) !Result {
        const full = try argv(self.allocator, self.options, args);
        defer self.allocator.free(full);
        const run = std.process.run(self.allocator, self.io, .{
            .argv = full,
            .environ_map = self.environ_map,
            .stdout_limit = .limited(output_limit),
            .stderr_limit = .limited(output_limit),
        }) catch |err| return switch (err) {
            error.FileNotFound => error.TmuxNotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.TmuxFailed,
        };
        const code: u8 = switch (run.term) {
            .exited => |code| code,
            else => {
                self.allocator.free(run.stdout);
                self.allocator.free(run.stderr);
                return error.TmuxFailed;
            },
        };
        return .{ .allocator = self.allocator, .exit_code = code, .stdout = run.stdout, .stderr = run.stderr };
    }

    /// Which kind of tmux the binary is, from its `-V`, which needs no server
    /// running. psmux names itself on a line of its own after a tmux version.
    /// tmux when it cannot be asked: the first real query will say why.
    pub fn kind(self: *Server) Kind {
        var result = self.exec(&.{"-V"}) catch return .tmux;
        defer result.deinit();
        var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "psmux ")) return .psmux;
        return .tmux;
    }
};

/// For psmux, the namespace tmm runs in, from the `TMUX` its pane was given:
/// `<directory>/<namespace>,<pid>,<n>`. Null for the default namespace, and
/// when there is no pane to go by.
pub fn psmuxNamespace(tmux_env: ?[]const u8) ?[]const u8 {
    const value = tmux_env orelse return null;
    const path = value[0 .. std.mem.indexOfScalar(u8, value, ',') orelse value.len];
    const name = path[(std.mem.lastIndexOfAny(u8, path, "/\\") orelse return null) + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, "default")) return null;
    return name;
}

test "the psmux namespace comes from the pane's TMUX" {
    try std.testing.expectEqualStrings("work", psmuxNamespace("/tmp/psmux-304/work,60576,0").?);
    try std.testing.expectEqualStrings("work", psmuxNamespace("C:\\Users\\a\\.psmux\\work,1,0").?);
    try std.testing.expect(psmuxNamespace("/tmp/psmux-304/default,60576,0") == null);
    try std.testing.expect(psmuxNamespace("") == null);
    try std.testing.expect(psmuxNamespace(null) == null);
}

test "argv puts the socket flags between the binary and the command" {
    const a = std.testing.allocator;
    const plain = try argv(a, .{}, &.{ "list-sessions", "-F", "#{session_id}" });
    defer a.free(plain);
    try std.testing.expectEqualStrings(default_bin, plain[0]);
    try std.testing.expectEqualStrings("list-sessions", plain[1]);
    try std.testing.expectEqual(@as(usize, 4), plain.len);

    const path = try argv(a, .{ .socket_path = "/tmp/s", .socket_name = "ignored", .tmux_bin = "/bin/tmux" }, &.{"ls"});
    defer a.free(path);
    try std.testing.expectEqualStrings("/bin/tmux", path[0]);
    try std.testing.expectEqualStrings("-S", path[1]);
    try std.testing.expectEqualStrings("/tmp/s", path[2]);
    try std.testing.expectEqualStrings("ls", path[3]);
    try std.testing.expectEqual(@as(usize, 4), path.len);

    const name = try argv(a, .{ .socket_name = "work" }, &.{"ls"});
    defer a.free(name);
    try std.testing.expectEqualStrings("-L", name[1]);
    try std.testing.expectEqualStrings("work", name[2]);
}

test "a missing binary is TmuxNotFound, and a refused command is a result" {
    const a = std.testing.allocator;
    var missing = Server.init(a, std.testing.io, .{ .tmux_bin = "/nonexistent/tmm-test/tmux" });
    try std.testing.expectError(error.TmuxNotFound, missing.exec(&.{"ls"}));

    // `false` stands in for a tmux that runs and refuses: exit code 1.
    var refusing = Server.init(a, std.testing.io, .{ .tmux_bin = "false" });
    var result = try refusing.exec(&.{"ls"});
    defer result.deinit();
    try std.testing.expect(!result.success());
}
