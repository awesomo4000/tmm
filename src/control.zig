// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! tmux control-mode (`tmux -C`) protocol: line parser, output decoder, and a
//! small command encoder. Pure and borrowing, like model.zig — the transport
//! (spawning `tmux -C attach`, reading lines, writing commands) lives in the
//! caller. Feed one line (newline stripped) per `Parser.feed`; every string in
//! the returned Event borrows from that line and is valid only until the next
//! feed, so copy anything you keep. `%output` payloads arrive octal-escaped —
//! call `decodeAlloc` to get the raw bytes.
//!
//! Protocol reference (tmux control.c / control-notify.c / cmd-queue.c):
//!   guard block:  %begin <t> <num> <flags> ... %end|%error <t> <num> <flags>
//!   %output %<pane> <escaped>
//!   %extended-output %<pane> <age> : <escaped>
//!   %layout-change <@win> <layout> <visible-layout> <raw-flags>
//!   %window-add|%window-close|%unlinked-window-add|%unlinked-window-close <@win>
//!   %window-renamed|%unlinked-window-renamed <@win> <name>
//!   %window-pane-changed <@win> <%pane>
//!   %session-changed <$sid> <name>   %session-renamed <$sid> <name>
//!   %sessions-changed   %session-window-changed <$sid> <@win>
//!   %pane-mode-changed <%pane>   %pause <%pane>   %continue <%pane>
//!   %client-session-changed <client> <$sid> <name>   %client-detached <client>
//!   %paste-buffer-changed <name>   %paste-buffer-deleted <name>
//!   %subscription-changed <name> ... : <value>
//!   %exit[ <reason>]

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Event = union(enum) {
    /// Raw pane output, still octal-escaped. Decode with decodeAlloc.
    output: struct { pane: []const u8, escaped: []const u8 },
    /// Pause-mode output; `age` is the milliseconds the block waited, as text.
    extended_output: struct { pane: []const u8, age: []const u8, escaped: []const u8 },
    layout_change: struct { window: []const u8, layout: []const u8, visible: []const u8, flags: []const u8 },
    window_add: []const u8,
    window_close: []const u8,
    unlinked_window_add: []const u8,
    unlinked_window_close: []const u8,
    window_renamed: struct { window: []const u8, name: []const u8 },
    unlinked_window_renamed: struct { window: []const u8, name: []const u8 },
    window_pane_changed: struct { window: []const u8, pane: []const u8 },
    session_changed: struct { session: []const u8, name: []const u8 },
    session_renamed: struct { session: []const u8, name: []const u8 },
    sessions_changed,
    session_window_changed: struct { session: []const u8, window: []const u8 },
    pane_mode_changed: []const u8,
    pause_pane: []const u8,
    continue_pane: []const u8,
    client_session_changed: struct { client: []const u8, session: []const u8, name: []const u8 },
    client_detached: []const u8,
    paste_buffer_changed: []const u8,
    paste_buffer_deleted: []const u8,
    /// Remainder after "%subscription-changed " — name, location and value. Left
    /// raw; shape varies (control.c has three forms) and callers that use
    /// subscriptions know which they asked for.
    subscription_changed: []const u8,
    exit: []const u8,
    /// A command-reply guard opened. `num` correlates with the command order.
    reply_begin: struct { num: []const u8, flags: []const u8 },
    /// One line of command-reply content (inside a guard block).
    reply_line: []const u8,
    /// A guard closed. `ok` is false for %error.
    reply_end: struct { num: []const u8, ok: bool },
    /// A line we did not recognise (kept whole, including any leading %).
    unknown: []const u8,
};

/// Stateful across lines only for guard-block tracking.
pub const Parser = struct {
    /// Depth of open %begin blocks. Notifications never appear inside a block
    /// (tmux defers them), so while depth > 0 every line is reply content until
    /// the matching %end/%error.
    depth: u32 = 0,

    pub fn feed(self: *Parser, line: []const u8) Event {
        if (self.depth > 0) return self.feedInGuard(line);
        if (after(line, "%begin ")) |rem| {
            self.depth = 1;
            return guardBegin(rem);
        }
        if (line.len == 0 or line[0] != '%') return .{ .unknown = line };
        return parseNotification(line);
    }

    fn feedInGuard(self: *Parser, line: []const u8) Event {
        // Reply content is not escaped, so a line of output could in principle
        // look like a guard; tmux clients disambiguate by the number, which we
        // surface rather than enforce. Nested %begin is tracked so a stray
        // inner block cannot close the outer one early.
        if (std.mem.startsWith(u8, line, "%begin ")) {
            self.depth += 1;
            return .{ .reply_line = line };
        }
        if (after(line, "%end ")) |rem| {
            self.depth -= 1;
            if (self.depth == 0) return .{ .reply_end = .{ .num = guardNumber(rem), .ok = true } };
            return .{ .reply_line = line };
        }
        if (after(line, "%error ")) |rem| {
            self.depth -= 1;
            if (self.depth == 0) return .{ .reply_end = .{ .num = guardNumber(rem), .ok = false } };
            return .{ .reply_line = line };
        }
        return .{ .reply_line = line };
    }
};

fn parseNotification(line: []const u8) Event {
    // No-argument notifications first (exact match).
    if (std.mem.eql(u8, line, "%sessions-changed")) return .sessions_changed;
    if (std.mem.eql(u8, line, "%exit")) return .{ .exit = "" };

    if (after(line, "%output ")) |rem| {
        const sp = std.mem.indexOfScalar(u8, rem, ' ') orelse return .{ .output = .{ .pane = rem, .escaped = "" } };
        return .{ .output = .{ .pane = rem[0..sp], .escaped = rem[sp + 1 ..] } };
    }
    if (after(line, "%extended-output ")) |rem| {
        const sep = std.mem.indexOf(u8, rem, " : ") orelse return .{ .unknown = line };
        var head = std.mem.splitScalar(u8, rem[0..sep], ' ');
        const pane = head.next() orelse return .{ .unknown = line };
        return .{ .extended_output = .{ .pane = pane, .age = head.rest(), .escaped = rem[sep + 3 ..] } };
    }
    if (after(line, "%layout-change ")) |rem| {
        var it = std.mem.splitScalar(u8, rem, ' ');
        const window = it.next() orelse return .{ .unknown = line };
        const layout = it.next() orelse return .{ .unknown = line };
        const visible = it.next() orelse "";
        return .{ .layout_change = .{ .window = window, .layout = layout, .visible = visible, .flags = it.rest() } };
    }
    if (after(line, "%window-pane-changed ")) |rem| {
        const two = twoFields(rem) orelse return .{ .unknown = line };
        return .{ .window_pane_changed = .{ .window = two[0], .pane = two[1] } };
    }
    if (after(line, "%unlinked-window-add ")) |rem| return .{ .unlinked_window_add = rem };
    if (after(line, "%unlinked-window-close ")) |rem| return .{ .unlinked_window_close = rem };
    if (after(line, "%unlinked-window-renamed ")) |rem| {
        const idn = idAndName(rem);
        return .{ .unlinked_window_renamed = .{ .window = idn.id, .name = idn.name } };
    }
    if (after(line, "%window-add ")) |rem| return .{ .window_add = rem };
    if (after(line, "%window-close ")) |rem| return .{ .window_close = rem };
    if (after(line, "%window-renamed ")) |rem| {
        const idn = idAndName(rem);
        return .{ .window_renamed = .{ .window = idn.id, .name = idn.name } };
    }
    if (after(line, "%session-window-changed ")) |rem| {
        const two = twoFields(rem) orelse return .{ .unknown = line };
        return .{ .session_window_changed = .{ .session = two[0], .window = two[1] } };
    }
    if (after(line, "%session-renamed ")) |rem| {
        const idn = idAndName(rem);
        return .{ .session_renamed = .{ .session = idn.id, .name = idn.name } };
    }
    if (after(line, "%session-changed ")) |rem| {
        const idn = idAndName(rem);
        return .{ .session_changed = .{ .session = idn.id, .name = idn.name } };
    }
    if (after(line, "%client-session-changed ")) |rem| {
        var it = std.mem.splitScalar(u8, rem, ' ');
        const client = it.next() orelse return .{ .unknown = line };
        const session = it.next() orelse return .{ .unknown = line };
        return .{ .client_session_changed = .{ .client = client, .session = session, .name = it.rest() } };
    }
    if (after(line, "%client-detached ")) |rem| return .{ .client_detached = rem };
    if (after(line, "%pane-mode-changed ")) |rem| return .{ .pane_mode_changed = rem };
    if (after(line, "%paste-buffer-changed ")) |rem| return .{ .paste_buffer_changed = rem };
    if (after(line, "%paste-buffer-deleted ")) |rem| return .{ .paste_buffer_deleted = rem };
    if (after(line, "%pause ")) |rem| return .{ .pause_pane = rem };
    if (after(line, "%continue ")) |rem| return .{ .continue_pane = rem };
    if (after(line, "%subscription-changed ")) |rem| return .{ .subscription_changed = rem };
    if (after(line, "%exit ")) |rem| return .{ .exit = rem };

    return .{ .unknown = line };
}

fn guardBegin(rem: []const u8) Event {
    // rem is "<t> <num> <flags>".
    var it = std.mem.splitScalar(u8, rem, ' ');
    _ = it.next(); // time
    const num = it.next() orelse "";
    return .{ .reply_begin = .{ .num = num, .flags = it.rest() } };
}

fn guardNumber(rem: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, rem, ' ');
    _ = it.next(); // time
    return it.next() orelse "";
}

fn after(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn twoFields(rem: []const u8) ?[2][]const u8 {
    const sp = std.mem.indexOfScalar(u8, rem, ' ') orelse return null;
    return .{ rem[0..sp], rem[sp + 1 ..] };
}

/// Split "<id> <name...>" where name may contain spaces (and may be empty).
fn idAndName(rem: []const u8) struct { id: []const u8, name: []const u8 } {
    const sp = std.mem.indexOfScalar(u8, rem, ' ') orelse return .{ .id = rem, .name = "" };
    return .{ .id = rem[0..sp], .name = rem[sp + 1 ..] };
}

/// Decode an octal-escaped `%output` payload into raw bytes. tmux escapes any
/// byte < 0x20 and the backslash itself as `\ooo` (three octal digits), leaving
/// everything else literal, so a backslash is always a 4-char escape.
pub fn decodeAlloc(alloc: Allocator, escaped: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, escaped.len);
    var i: usize = 0;
    while (i < escaped.len) {
        if (escaped[i] == '\\' and i + 4 <= escaped.len and
            isOctal(escaped[i + 1]) and isOctal(escaped[i + 2]) and isOctal(escaped[i + 3]))
        {
            const b = (octal(escaped[i + 1]) << 6) | (octal(escaped[i + 2]) << 3) | octal(escaped[i + 3]);
            out.appendAssumeCapacity(b);
            i += 4;
        } else {
            out.appendAssumeCapacity(escaped[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

inline fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}
inline fn octal(c: u8) u8 {
    return c - '0';
}

/// Commands to write to the control client's stdin. Each returns an allocated,
/// newline-terminated line the caller sends and frees.
pub const Command = struct {
    /// Set the control client's render size (the window region you present).
    pub fn refreshSize(alloc: Allocator, w: u32, h: u32) ![]u8 {
        return std.fmt.allocPrint(alloc, "refresh-client -C {d}x{d}\n", .{ w, h });
    }
    /// Set the size of one window for this client (@id:WxH).
    pub fn refreshWindowSize(alloc: Allocator, window: []const u8, w: u32, h: u32) ![]u8 {
        // window includes its '@' sigil; strip it for the @%u: form.
        const id = if (window.len != 0 and window[0] == '@') window[1..] else window;
        return std.fmt.allocPrint(alloc, "refresh-client -C @{s}:{d}x{d}\n", .{ id, w, h });
    }
    /// `sendKeysHex` into a caller-supplied buffer, for the key path, which
    /// must not allocate: a keystroke is the one thing in tmm with a
    /// deadline, and an allocator is a lock and a syscall it does not need.
    /// Returns `error.NoSpaceLeft` if the buffer is too small, which leaves
    /// the caller free to fall back to the allocating form.
    pub fn sendKeysHexBuf(buf: []u8, pane: []const u8, bytes: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("send-keys -t ");
        try w.writeAll(pane);
        try w.writeAll(" -H");
        for (bytes) |b| try w.print(" {x:0>2}", .{b});
        try w.writeByte('\n');
        return w.buffered();
    }

    /// Send raw input bytes to a pane as hex key codes (survives any byte).
    pub fn sendKeysHex(alloc: Allocator, pane: []const u8, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "send-keys -t ");
        try out.appendSlice(alloc, pane);
        try out.appendSlice(alloc, " -H");
        for (bytes) |b| {
            var buf: [3]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&buf, " {x:0>2}", .{b}) catch unreachable);
        }
        try out.append(alloc, '\n');
        return out.toOwnedSlice(alloc);
    }
    /// Send a key to *this client* rather than to a pane, so tmux looks it up
    /// in the client's own key table and runs whatever is bound there.
    ///
    /// This is the whole of tmm's tmux-binding support: `-K` is documented as
    /// sending "to target-client, so they are looked up in the client's key
    /// table", and a control-mode client has one like any other. No `-c` is
    /// needed because a command written on the stream is already attributed to
    /// that client. `name` must already be in tmux's spelling and escaped for
    /// its command parser; `tmuxkey.name` is what produces it.
    ///
    /// On the caller-supplied buffer for the same reason `sendKeysHexBuf` is:
    /// this is reached from the key path.
    pub fn sendKeyNameBuf(buf: []u8, key_name: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("send-keys -K ");
        try w.writeAll(key_name);
        try w.writeByte('\n');
        return w.buffered();
    }
    /// Make a pane the session's active one, so tmux agrees with tmm about
    /// which pane has the keyboard.
    ///
    /// Without this the two diverge the moment a pane is clicked: tmm moves
    /// the keyboard, tmux does not, and every binding afterwards acts on the
    /// pane tmux still considers active -- `prefix z` zooms a pane you are
    /// not typing in. tmux answers with `%window-pane-changed`, which the
    /// compositor already follows, so the two end up agreeing either way.
    pub fn selectPaneBuf(buf: []u8, pane: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("select-pane -t ");
        try w.writeAll(pane);
        try w.writeByte('\n');
        return w.buffered();
    }
    /// Point this client at a session, the way `prefix (` does. tmux answers
    /// with `%session-changed`, which the compositor follows.
    pub fn switchClientBuf(buf: []u8, session: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("switch-client -t ");
        try w.writeAll(session);
        try w.writeByte('\n');
        return w.buffered();
    }
    /// Make a window the session's current one. Answered with
    /// `%session-window-changed`.
    pub fn selectWindowBuf(buf: []u8, window: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("select-window -t ");
        try w.writeAll(window);
        try w.writeByte('\n');
        return w.buffered();
    }
    /// Seed a pane's current screen: escaped, with background, whole history off.
    pub fn capturePane(alloc: Allocator, pane: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "capture-pane -p -e -t {s}\n", .{pane});
    }
};

test "output notification splits pane from escaped payload" {
    var p: Parser = .{};
    const ev = p.feed("%output %3 hello\\015\\012");
    try std.testing.expectEqualStrings("%3", ev.output.pane);
    try std.testing.expectEqualStrings("hello\\015\\012", ev.output.escaped);
}

test "decode reverses tmux octal escaping including backslash" {
    const a = std.testing.allocator;
    const out = try decodeAlloc(a, "ab\\015\\012\\134z");
    defer a.free(out);
    try std.testing.expectEqualStrings("ab\r\n\\z", out);
}

test "decode leaves a malformed escape literal" {
    const a = std.testing.allocator;
    const out = try decodeAlloc(a, "x\\9y\\12");
    defer a.free(out);
    try std.testing.expectEqualStrings("x\\9y\\12", out);
}

test "layout-change exposes window and layout strings" {
    var p: Parser = .{};
    const ev = p.feed("%layout-change @1 bb62,80x24,0,0,1 cc00,80x24,0,0,1 *");
    try std.testing.expectEqualStrings("@1", ev.layout_change.window);
    try std.testing.expectEqualStrings("bb62,80x24,0,0,1", ev.layout_change.layout);
    try std.testing.expectEqualStrings("cc00,80x24,0,0,1", ev.layout_change.visible);
    try std.testing.expectEqualStrings("*", ev.layout_change.flags);
}

test "window and session notifications keep sigils and names with spaces" {
    var p: Parser = .{};
    try std.testing.expectEqualStrings("@2", p.feed("%window-add @2").window_add);
    const wr = p.feed("%window-renamed @2 my project").window_renamed;
    try std.testing.expectEqualStrings("@2", wr.window);
    try std.testing.expectEqualStrings("my project", wr.name);
    const wp = p.feed("%window-pane-changed @2 %5").window_pane_changed;
    try std.testing.expectEqualStrings("@2", wp.window);
    try std.testing.expectEqualStrings("%5", wp.pane);
    const sc = p.feed("%session-changed $0 main").session_changed;
    try std.testing.expectEqualStrings("$0", sc.session);
    try std.testing.expectEqualStrings("main", sc.name);
    try std.testing.expect(p.feed("%sessions-changed") == .sessions_changed);
}

test "sessions-changed is not confused with session-changed or session-window-changed" {
    var p: Parser = .{};
    try std.testing.expect(p.feed("%sessions-changed") == .sessions_changed);
    const sw = p.feed("%session-window-changed $1 @4").session_window_changed;
    try std.testing.expectEqualStrings("$1", sw.session);
    try std.testing.expectEqualStrings("@4", sw.window);
}

test "guard block frames command replies and resumes notifications after" {
    var p: Parser = .{};
    const b = p.feed("%begin 1700000000 7 1");
    try std.testing.expectEqualStrings("7", b.reply_begin.num);
    try std.testing.expectEqualStrings("line one", p.feed("line one").reply_line);
    // A reply line that merely looks like a notification stays reply content.
    try std.testing.expectEqualStrings("%output not-really", p.feed("%output not-really").reply_line);
    const e = p.feed("%end 1700000000 7 1");
    try std.testing.expect(e.reply_end.ok);
    try std.testing.expectEqualStrings("7", e.reply_end.num);
    // Back to normal notification parsing.
    try std.testing.expectEqualStrings("%9", p.feed("%output %9 x").output.pane);
}

test "error guard closes the block and reports failure" {
    var p: Parser = .{};
    _ = p.feed("%begin 100 3 0");
    _ = p.feed("some error text");
    const e = p.feed("%error 100 3 0");
    try std.testing.expect(!e.reply_end.ok);
    try std.testing.expect(p.depth == 0);
}

test "extended-output separates pane, age and payload" {
    var p: Parser = .{};
    const ev = p.feed("%extended-output %2 42 : da\\011ta");
    try std.testing.expectEqualStrings("%2", ev.extended_output.pane);
    try std.testing.expectEqualStrings("42", ev.extended_output.age);
    try std.testing.expectEqualStrings("da\\011ta", ev.extended_output.escaped);
}

test "pause, continue, exit and unknown lines" {
    var p: Parser = .{};
    try std.testing.expectEqualStrings("%1", p.feed("%pause %1").pause_pane);
    try std.testing.expectEqualStrings("%1", p.feed("%continue %1").continue_pane);
    try std.testing.expectEqualStrings("", p.feed("%exit").exit);
    try std.testing.expectEqualStrings("server exited", p.feed("%exit server exited").exit);
    try std.testing.expectEqualStrings("%nonsense", p.feed("%nonsense").unknown);
}

test "command encoders format tmux lines" {
    const a = std.testing.allocator;
    const sz = try Command.refreshSize(a, 120, 40);
    defer a.free(sz);
    try std.testing.expectEqualStrings("refresh-client -C 120x40\n", sz);
    const ws = try Command.refreshWindowSize(a, "@3", 80, 24);
    defer a.free(ws);
    try std.testing.expectEqualStrings("refresh-client -C @3:80x24\n", ws);
    var kbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "send-keys -K C-a\n",
        try Command.sendKeyNameBuf(&kbuf, "C-a"),
    );
    const keys = try Command.sendKeysHex(a, "%4", "hi\x1b");
    defer a.free(keys);
    try std.testing.expectEqualStrings("send-keys -t %4 -H 68 69 1b\n", keys);
    const cap = try Command.capturePane(a, "%4");
    defer a.free(cap);
    try std.testing.expectEqualStrings("capture-pane -p -e -t %4\n", cap);
}
