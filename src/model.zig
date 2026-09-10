// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// tmux's n: modifier counts bytes. Each field is length:payload; a record ends
/// with a newline. Payloads may themselves contain newlines or any delimiter.
pub fn format(comptime fields: []const []const u8) []const u8 {
    return comptime blk: {
        var result: []const u8 = "";
        for (fields) |field| result = result ++ "#{n:" ++ field ++ "}:#{" ++ field ++ "}";
        break :blk result;
    };
}

pub fn records(comptime N: usize, alloc: Allocator, data: []const u8) ![][N][]const u8 {
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
    session: []const u8,
    terminal: ?[]const u8 = null,
    pub fn same(a: Client, b: Client) bool {
        return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.pid, b.pid) and std.mem.eql(u8, a.created, b.created);
    }
};
pub const Session = struct { id: []const u8, name: []const u8, path: []const u8 };
pub const Pane = struct { session: []const u8, window: []const u8, id: []const u8, cwd: []const u8, command: []const u8, agent: []const u8, state: []const u8, status: []const u8, agent_source: []const u8 = "none", status_source: []const u8 = "unknown", status_rule: []const u8 = "", run_identity: []const u8 = "", completion: u64 = 0, unread: bool = false, interrupted: bool = false };

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
    const rows = try records(2, a, "8:é|\n\tfoo0:\n1:x3:a:b\n");
    defer a.free(rows);
    try std.testing.expectEqualStrings("é|\n\tfoo", rows[0][0]);
    try std.testing.expectEqualStrings("a:b", rows[1][1]);
    for ([_][]const u8{ "99:x\n", "1:x", "-1:x\n", "1:xextra\n", "999999999999999999999999999999999:x\n" }) |bad|
        try std.testing.expectError(error.MalformedRecord, records(1, a, bad));
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

pub fn agentCommand(command: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(command);
    inline for (.{ "codex", "claude", "aider", "opencode", "gemini" }) |agent| {
        if (std.mem.eql(u8, name, agent)) return agent;
    }
    return null;
}
pub const Process = struct { pid: u32, parent: u32, command: []const u8 };
pub fn parseProcesses(a: Allocator, text: []const u8) ![]Process {
    var result: std.ArrayList(Process) = .empty;
    errdefer result.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_text| {
        var fields = std.mem.tokenizeAny(u8, line_text, " \t");
        const pid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const parent = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const command = std.mem.trim(u8, fields.rest(), " \t");
        try result.append(a, .{ .pid = pid, .parent = parent, .command = command });
    }
    return result.toOwnedSlice(a);
}
pub fn processAgent(processes: []const Process, root: u32) ?[]const u8 {
    return if (processAgentInfo(processes, root)) |info| info.name else null;
}
pub fn processAgentInfo(processes: []const Process, root: u32) ?struct { name: []const u8, pid: u32 } {
    for (processes) |process| {
        const agent = agentCommand(process.command) orelse continue;
        var ancestor = process.pid;
        // A corrupt or racing process table must not cause an endless walk.
        for (0..processes.len + 1) |_| {
            if (ancestor == root) return .{ .name = agent, .pid = process.pid };
            var parent: ?u32 = null;
            for (processes) |p| if (p.pid == ancestor) {
                parent = p.parent;
                break;
            };
            const next = parent orelse break;
            if (next == 0 or next == ancestor) break;
            ancestor = next;
        }
    }
    return null;
}
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
test "agent detection follows wrappers without matching unrelated names" {
    const a = std.testing.allocator;
    const processes = try parseProcesses(a, "10 1 /bin/bash\n11 10 node\n12 11 /tmp/test agent/codex\n20 1 claude\n30 31 codex\n31 30 node\n");
    defer a.free(processes);
    try std.testing.expectEqualStrings("codex", processAgent(processes, 10).?);
    try std.testing.expect(processAgent(processes, 99) == null);
    try std.testing.expect(agentCommand("codex-helper") == null);
    try std.testing.expect(agentCommand("node") == null);
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
    _ = @import("status.zig");
}
