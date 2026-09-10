// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Detection approach and selected UI signals adapted from Herdr's Apache-2.0
// manifests. See THIRD_PARTY_NOTICES.md for source revision and scope.
const std = @import("std");
pub const State = enum { unknown, working, blocked, idle, done };
pub const Verdict = struct { state: State, rule: []const u8, interrupted: bool = false };
fn has(text: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, needle) != null;
}
fn starts(text: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, text, needle);
}
// Claude cycles these glyphs on its live activity line. Completed summaries
// use similar glyphs but have no ellipsis, so they must not imply working.
fn claudeActivity(line: []const u8) bool {
    inline for (.{ "*", "·", "✢", "✶", "✻", "✽" }) |glyph| {
        if (starts(line, glyph ++ " ")) {
            const body = std.mem.trim(u8, line[glyph.len + 1 ..], " ");
            const ellipsis = std.mem.indexOf(u8, body, "…") orelse return false;
            if (ellipsis == 0) return false;
            const tail = std.mem.trim(u8, body[ellipsis + "…".len ..], " ");
            if (tail.len == 0) return true;
            if (!starts(tail, "(")) return false;
            var i: usize = 1;
            while (i < tail.len and std.ascii.isDigit(tail[i])) : (i += 1) {}
            return i > 1 and i + 1 < tail.len and
                std.mem.indexOfScalar(u8, "smh", tail[i]) != null and
                (tail[i + 1] == ' ' or starts(tail[i + 1 ..], "·"));
        }
    }
    return false;
}
fn titleWorking(title: []const u8) bool {
    if (title.len == 0) return false;
    const size = std.unicode.utf8ByteSequenceLength(title[0]) catch return false;
    if (title.len <= size or title[size] != ' ') return false;
    const cp = std.unicode.utf8Decode(title[0..size]) catch return false;
    return (cp >= 0x2800 and cp <= 0x28ff) or (cp >= 0x25d0 and cp <= 0x25d3);
}
pub fn metadata(value: []const u8) State {
    const end = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
    return std.meta.stringToEnum(State, value[0..end]) orelse .unknown;
}

/// Only the latest nonempty lines are evidence. Scrollback and quoted text
/// elsewhere in a transcript must not masquerade as a current control.
pub fn classify(agent: []const u8, screen: []const u8, title: []const u8) Verdict {
    if (!std.mem.eql(u8, agent, "codex") and !std.mem.eql(u8, agent, "claude"))
        return .{ .state = .unknown, .rule = "unsupported-agent" };
    var lines: [12][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitBackwardsScalar(u8, screen, '\n');
    while (iterator.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        lines[count] = line;
        count += 1;
        if (count == lines.len) break;
    }
    var prompt = false;
    var footer = false;
    var cancel = false;
    var confirm = false;
    var interrupted = false;
    for (lines[0..@min(count, 6)]) |line| {
        if (has(line, "q to quit") and has(line, "scroll")) return .{ .state = .unknown, .rule = "transcript-view" };
        if (starts(line, "■ Conversation interrupted")) interrupted = true;
        if (starts(line, "›") or starts(line, "❯")) {
            prompt = true;
            continue;
        }
        if (prompt) continue; // old transcript above the current prompt is not a blocker
        if (has(line, "context") or has(line, "? for shortcuts") or has(line, "shift+tab to cycle") or has(line, "bypass permissions on")) footer = true;
        // Approval hints are standalone controls, not arbitrary transcript matches.
        if (starts(line, "Press enter to confirm or esc to cancel") or starts(line, "Enter to submit answer") or starts(line, "Enter to submit all"))
            return .{ .state = .blocked, .rule = "approval-controls" };
        if (has(line, "esc to cancel")) cancel = true;
        if (has(line, "enter to confirm") or has(line, "enter to select")) confirm = true;
    }
    if (std.mem.eql(u8, agent, "claude") and cancel and confirm)
        return .{ .state = .blocked, .rule = "claude-approval-controls" };
    if (std.mem.eql(u8, agent, "codex") and has(title, "Action Required"))
        return .{ .state = .blocked, .rule = "codex-title-approval" };
    if (!interrupted) {
        for (lines[0..@min(count, 6)]) |line| {
            if ((starts(line, "• Working (") or starts(line, "◦ Working (")) and has(line, "esc to interrupt)"))
                return .{ .state = .working, .rule = "codex-working-control" };
        }
        if (std.mem.eql(u8, agent, "claude")) for (lines[0..count]) |line| {
            if (claudeActivity(line)) return .{ .state = .working, .rule = "claude-activity-line" };
            if ((starts(line, "⏵") or starts(line, "⏸") or starts(line, "✻") or starts(line, "✽") or starts(line, "✢") or starts(line, "*")) and has(line, "esc to interrupt"))
                return .{ .state = .working, .rule = "claude-working-control" };
        };
        if (titleWorking(title)) return .{ .state = .working, .rule = "title-spinner" };
    }
    if (prompt and (footer or interrupted)) return .{ .state = .idle, .rule = "live-input-prompt", .interrupted = interrupted };
    return .{ .state = .unknown, .rule = "no-current-signal" };
}

pub const Track = struct {
    observed_working: bool = false,
    idle_samples: u8 = 0,
    generation: u64 = 0,
    seen: u64 = 0,
    last_done: ?u64 = null,
    visited: bool = false,
    pub fn observe(self: *Track, verdict: Verdict, receipt: ?[]const u8) void {
        self.visited = true;
        if (verdict.interrupted) {
            self.observed_working = false;
            self.idle_samples = 0;
        }
        switch (verdict.state) {
            .working => {
                self.observed_working = true;
                self.idle_samples = 0;
            },
            .blocked => {
                self.idle_samples = 0;
            },
            .unknown => {
                self.idle_samples = 0;
            },
            .idle => {
                if (self.observed_working) {
                    self.idle_samples +|= 1;
                    if (self.idle_samples >= 2) {
                        self.generation += 1;
                        self.observed_working = false;
                        self.idle_samples = 0;
                    }
                }
            },
            .done => {
                const stamp = std.hash.Wyhash.hash(0, receipt orelse "done");
                if (self.observed_working or self.last_done == null or self.last_done.? != stamp) self.generation += 1;
                self.last_done = stamp;
                self.observed_working = false;
                self.idle_samples = 0;
            },
        }
    }
    pub fn acknowledge(self: *Track, generation: u64) void {
        self.seen = @max(self.seen, @min(generation, self.generation));
    }
    pub fn unread(self: Track) bool {
        return self.generation > self.seen;
    }
};
test "live controls outrank prompt and old transcript is not evidence" {
    const t = std.testing;
    try t.expectEqual(State.working, classify("codex", "• Working (2s • esc to interrupt)\n› Ask Codex\n50% context left", "").state);
    try t.expectEqual(State.blocked, classify("codex", "› Allow command?\nPress enter to confirm or esc to cancel", "").state);
    try t.expectEqual(State.idle, classify("codex", "› Ask Codex\n50% context left", "").state);
    try t.expectEqual(State.idle, classify("codex", "Press enter to confirm or esc to cancel\n› Ask Codex\n50% context left", "").state);
    try t.expectEqual(State.unknown, classify("codex", "some quiet output", "hostname").state);
    try t.expectEqual(State.unknown, classify("codex", "• Working (2s • esc to interrupt)\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13", "").state);
    try t.expectEqual(State.blocked, classify("claude", "Enter to select · Esc to cancel", "").state);
}
test "completion requires observed work and stable idle; receipts acknowledge separately" {
    var track: Track = .{};
    track.observe(.{ .state = .idle, .rule = "test" }, null);
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .working, .rule = "test" }, null);
    track.observe(.{ .state = .idle, .rule = "test" }, null);
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .idle, .rule = "test" }, null);
    try std.testing.expect(track.unread());
    track.acknowledge(1);
    track.observe(.{ .state = .done, .rule = "test" }, "done:123");
    track.acknowledge(1); // an old click cannot erase a newer completion
    try std.testing.expect(track.unread());
    track.acknowledge(2);
    track.observe(.{ .state = .done, .rule = "test" }, "done:123");
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .working, .rule = "test" }, null);
    track.observe(.{ .state = .idle, .rule = "test", .interrupted = true }, null);
    track.observe(.{ .state = .idle, .rule = "test" }, null);
    try std.testing.expect(!track.unread());
}

test "Claude activity without interrupt hint completes only after idle" {
    const t = std.testing;
    const idle = "────────────────\n❯ \n────────────────\nshift+tab to cycle\n";
    inline for (.{ "*", "·", "✢", "✶", "✻", "✽" }) |glyph| {
        try t.expectEqual(State.working, classify("claude", glyph ++ " Thinking…\n" ++ idle, "").state);
        try t.expectEqual(State.working, classify("claude", glyph ++ " Thinking… (2s · ↓ 12 tokens)\n" ++ idle, "").state);
    }
    try t.expectEqual(State.idle, classify("claude", "✻ Cogitated for 1s\n" ++ idle, "✳ Claude Code").state);
    try t.expectEqual(State.idle, classify("claude", "A response mentioning Thinking…\n" ++ idle, "").state);
    try t.expectEqual(State.working, classify("claude", idle, "⣿ Claude Code").state);
    try t.expectEqual(State.working, classify("claude", idle, "◓ Claude Code").state);
    try t.expectEqual(State.blocked, classify("claude", "Enter to select · Esc to cancel", "◓ Claude Code").state);
    var track: Track = .{};
    track.observe(classify("claude", "✶ Thinking…\n" ++ idle, ""), null);
    track.observe(classify("claude", idle, "✳ Claude Code"), null);
    track.observe(classify("claude", idle, "✳ Claude Code"), null);
    try t.expect(track.unread());
}
