// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const tmux = @import("tmux.zig");
const agentstate = @import("agentstate.zig");
const Allocator = std.mem.Allocator;

/// How the fields of a listed record are told apart.
pub const Framing = enum {
    /// tmux's n: modifier counts bytes. Each field is length:payload; a record
    /// ends with a newline. Payloads may themselves contain newlines or any
    /// delimiter.
    lengths,
    /// For psmux, which has no n: modifier: fields are apart by the ASCII unit
    /// separator, and a record ends with a newline. A payload holding either
    /// breaks its record, which is then refused rather than misread.
    ///
    /// Pane ids are asked for with their session and window, as `$1:@2.%3`.
    /// psmux numbers panes per session, so a bare `%3` can be a pane in more
    /// than one session; the qualified form is unique and is a target psmux
    /// resolves to that one pane, so it serves as the id everywhere.
    separated,

    pub fn of(kind: tmux.Kind) Framing {
        return switch (kind) {
            .tmux => .lengths,
            .psmux => .separated,
        };
    }
};

const separator = "\x1f";

pub fn format(comptime framing: Framing, comptime fields: []const []const u8) []const u8 {
    return comptime blk: {
        var result: []const u8 = "";
        for (fields, 0..) |field, i| result = result ++ switch (framing) {
            .lengths => "#{n:" ++ field ++ "}:#{" ++ field ++ "}",
            .separated => (if (i > 0) separator else "") ++
                (if (std.mem.eql(u8, field, "pane_id")) "#{session_id}:#{window_id}.#{pane_id}" else "#{" ++ field ++ "}"),
        };
        break :blk result;
    };
}

pub fn records(comptime N: usize, framing: Framing, alloc: Allocator, data: []const u8) ![][N][]const u8 {
    return switch (framing) {
        .lengths => lengthRecords(N, alloc, data),
        .separated => separatedRecords(N, alloc, data),
    };
}

fn separatedRecords(comptime N: usize, alloc: Allocator, data: []const u8) ![][N][]const u8 {
    var list: std.ArrayList([N][]const u8) = .empty;
    errdefer list.deinit(alloc);
    if (data.len > 0 and data[data.len - 1] != '\n') return error.MalformedRecord;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (lines.index == null) break; // after the last newline
        var row: [N][]const u8 = undefined;
        var fields = std.mem.splitSequence(u8, line, separator);
        for (&row) |*field| field.* = fields.next() orelse return error.MalformedRecord;
        if (fields.next() != null) return error.MalformedRecord;
        try list.append(alloc, row);
    }
    return list.toOwnedSlice(alloc);
}

fn lengthRecords(comptime N: usize, alloc: Allocator, data: []const u8) ![][N][]const u8 {
    var list: std.ArrayList([N][]const u8) = .empty;
    errdefer list.deinit(alloc);
    var pos: usize = 0;
    while (pos < data.len) {
        var row: [N][]const u8 = undefined;
        for (&row) |*field| {
            const end = std.mem.indexOfScalarPos(u8, data, pos, ':') orelse return error.MalformedRecord;
            if (end == pos) return error.MalformedRecord;
            for (data[pos..end]) |c| if (!std.ascii.isDigit(c)) return error.MalformedRecord;
            const len = std.fmt.parseInt(usize, data[pos..end], 10) catch return error.MalformedRecord;
            pos = end + 1;
            if (len > data.len - pos) return error.MalformedRecord;
            field.* = data[pos..][0..len];
            pos += len;
        }
        if (pos == data.len or data[pos] != '\n') return error.MalformedRecord;
        pos += 1;
        try list.append(alloc, row);
    }
    return list.toOwnedSlice(alloc);
}

pub const Client = struct {
    name: []const u8,
    pid: []const u8,
    created: []const u8,
    /// Where this client currently is. tmux expands these per client when
    /// `list-clients` formats them, which is the only way to ask: a
    /// `display-message -c` reports the server's current pane, not this
    /// client's, so it answers the same for every client. See backend.clients.
    session: []const u8,
    window: []const u8 = "",
    pane: []const u8 = "",
    cwd: []const u8 = "",
    terminal: ?[]const u8 = null,
    pub fn same(a: Client, b: Client) bool {
        return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.pid, b.pid) and std.mem.eql(u8, a.created, b.created);
    }
};
pub const Session = struct { id: []const u8, name: []const u8, path: []const u8 };
/// `reported` is the OSC 7501 record a reporter wrote to the `@tmm_status`
/// pane option, still as the payload text; see src/reported.zig for why it
/// arrives as a pane option rather than in band. `at_prompt` is whether the
/// pane's own shell runs nothing, which ends an in-progress record; see
/// `atPrompt`.
pub const Pane = struct { session: []const u8, window: []const u8, id: []const u8, cwd: []const u8, command: []const u8, agent: []const u8, state: []const u8, status: []const u8, activity: []const u8 = "", reported: []const u8 = "", at_prompt: bool = false, agent_source: []const u8 = "none", status_source: []const u8 = "unknown", status_rule: []const u8 = "", run_identity: []const u8 = "", completion: u64 = 0, unread: bool = false, interrupted: bool = false };

/// Strip terminal controls from display text without changing internal IDs.
pub fn display(alloc: Allocator, value: []const u8) ![]const u8 {
    const result = try alloc.dupe(u8, value);
    for (result) |*c| if (c.* < 32 or c.* == 127) {
        c.* = ' ';
    };
    if (!std.unicode.utf8ValidateSlice(result)) {
        for (result) |*c| if (c.* >= 128) {
            c.* = '?';
        };
    }
    return result;
}

test "length frames preserve unusual names and reject broken records" {
    const a = std.testing.allocator;
    const rows = try records(2, .lengths, a, "8:é|\n\tfoo0:\n1:x3:a:b\n");
    defer a.free(rows);
    try std.testing.expectEqualStrings("é|\n\tfoo", rows[0][0]);
    try std.testing.expectEqualStrings("a:b", rows[1][1]);
    for ([_][]const u8{ "99:x\n", "1:x", "-1:x\n", "1:xextra\n", "999999999999999999999999999999999:x\n" }) |bad|
        try std.testing.expectError(error.MalformedRecord, records(1, .lengths, a, bad));
}
test "separated records split on the unit separator and refuse a wrong count" {
    const a = std.testing.allocator;
    const rows = try records(2, .separated, a, "$1:@1.%2\x1fa b:c\n$2:@1.%2\x1f\n");
    defer a.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("a b:c", rows[0][1]);
    try std.testing.expectEqualStrings("$2:@1.%2", rows[1][0]);
    try std.testing.expectEqualStrings("", rows[1][1]);
    const none = try records(2, .separated, a, "");
    try std.testing.expectEqual(@as(usize, 0), none.len);
    // A newline inside a payload splits its record into two short ones.
    for ([_][]const u8{ "a\x1fb\x1fc\n", "a\n", "a\x1fb", "a\x1fb\nc\n" }) |bad|
        try std.testing.expectError(error.MalformedRecord, records(2, .separated, a, bad));
    try std.testing.expectEqualStrings("#{session_id}\x1f#{session_id}:#{window_id}.#{pane_id}", format(.separated, &.{ "session_id", "pane_id" }));
}
test "reused tty does not inherit client identity" {
    const c: Client = .{ .name = "/tmp/test-tty", .pid = "12", .created = "100", .session = "$0" };
    var other = c;
    other.session = "$1";
    try std.testing.expect(c.same(other));
    other.pid = "13";
    try std.testing.expect(!c.same(other));
    other = c;
    other.created = "101";
    try std.testing.expect(!c.same(other));
}

pub const Process = agentstate.Process;
const parseProcesses = agentstate.parseProcesses;

pub const Indicator = struct { symbol: []const u8, color: u8 };
pub fn agentIndicator(state: []const u8) Indicator {
    const end = std.mem.indexOfScalar(u8, state, ':') orelse state.len;
    const name = state[0..end];
    if (std.mem.eql(u8, name, "working")) return .{ .symbol = "●", .color = 6 };
    if (std.mem.eql(u8, name, "blocked")) return .{ .symbol = "!", .color = 3 };
    if (std.mem.eql(u8, name, "done")) return .{ .symbol = "✓", .color = 2 };
    if (std.mem.eql(u8, name, "idle")) return .{ .symbol = "○", .color = 8 };
    return .{ .symbol = "?", .color = 8 };
}
test "presence alone remains unknown, explicit status selects symbol" {
    try std.testing.expectEqualStrings("?", agentIndicator("").symbol);
    try std.testing.expectEqualStrings("●", agentIndicator("working:123").symbol);
    try std.testing.expectEqualStrings("!", agentIndicator("blocked:123").symbol);
    try std.testing.expectEqualStrings("✓", agentIndicator("done:123").symbol);
}

pub fn validSessionName(name: []const u8) bool {
    if (std.mem.trim(u8, name, " ").len == 0 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 32 or c == 127 or c == '.' or c == ':') return false;
    return true;
}
test "session name validation keeps unicode and shell punctuation literal" {
    try std.testing.expect(validSessionName("project é $foo; [bar]"));
    try std.testing.expect(!validSessionName(""));
    try std.testing.expect(!validSessionName("a:b"));
    try std.testing.expect(!validSessionName("a.b"));
    try std.testing.expect(!validSessionName("a\nb"));
}

pub fn terminalOwner(processes: []const Process, pid: u32) ?[]const u8 {
    var current = pid;
    for (0..processes.len + 1) |_| {
        var found: ?Process = null;
        for (processes) |p| if (p.pid == current) {
            found = p;
            break;
        };
        const process = found orelse return null;
        const name = std.fs.path.basename(process.command);
        const apps = .{
            .{ "ghostty", "Ghostty" },                      .{ "iTerm2", "iTerm2" },       .{ "Terminal", "Terminal" },
            .{ "kitty", "Kitty" },                          .{ "alacritty", "Alacritty" }, .{ "wezterm-gui", "WezTerm" },
            .{ "gnome-terminal-server", "GNOME Terminal" }, .{ "konsole", "Konsole" },     .{ "foot", "foot" },
            .{ "sshd", "SSH" },
        };
        inline for (apps) |app| if (std.ascii.eqlIgnoreCase(name, app[0])) return app[1];
        if (process.parent == 0 or process.parent == current) return null;
        current = process.parent;
    }
    return null;
}
test "terminal owner follows login and shell, stops at SSH" {
    const a = std.testing.allocator;
    const p = try parseProcesses(a, "1 0 launchd\n10 1 /Applications/Ghostty.app/Contents/MacOS/ghostty\n11 10 login\n12 11 bash\n13 12 tmux\n20 1 sshd\n21 20 bash\n22 21 tmux\n30 31 bash\n31 30 login\n");
    defer a.free(p);
    try std.testing.expectEqualStrings("Ghostty", terminalOwner(p, 13).?);
    try std.testing.expectEqualStrings("SSH", terminalOwner(p, 22).?);
    try std.testing.expect(terminalOwner(p, 30) == null);
    try std.testing.expect(terminalOwner(p, 99) == null);
}

test {
    _ = @import("reported.zig");
    _ = @import("agentstate.zig");
    _ = @import("status.zig");
    _ = @import("control.zig");
    _ = @import("quiet.zig");
    _ = @import("tmux.zig");
    _ = @import("reconcile.zig");
    _ = @import("state.zig");
    _ = @import("aurora.zig");
    _ = @import("banner.zig");
    _ = @import("sidebar.zig");
    _ = @import("order.zig");
}
