// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! An OSC 7501 record as a tmux pane option.
//!
//! tmm reads tmux over control mode and never sees a pane's own bytes, so an
//! OSC 7501 written to a pane cannot reach it in band. `%output` on a control
//! stream would not help either: it arrives only for the session that client
//! is attached to, so decoding it would cover one session out of however many
//! the sidebar lists. Measured, not assumed: a control client attached to
//! session A is told nothing about output in session B.
//!
//! So a reporter writes the record to a tmux pane option, `@tmm_status`, which
//! tmm reads for every pane on the server in the `list-panes -a` query it
//! already makes. tmm has read pane options for agent state for a while
//! (`@agent_state` and friends), so this is the established channel here rather
//! than a new one; what is new is carrying the whole OSC 7501 vocabulary over
//! it instead of a bare state word, so `error`, a blocked kind, a percentage
//! and a title all survive.
//!
//! The payload is byte for byte the one the escape sequence carries, which is
//! the point of this module: one vocabulary and one parser, whichever way a
//! reporter sends it.

const std = @import("std");
const sidebar = @import("sidebar.zig");

/// The pane option a reporter writes. Read in `backend.zig`'s pane query.
pub const option = "@tmm_status";

/// The specification's limits, revision 0.4. A report that breaks one is
/// discarded whole. The sequence limit covers OSC through ST, which the pane
/// option does not carry, so the payload is held to it as an upper bound.
const max_sequence = 4096;
const max_key = 16;
const max_title_encoded = 256;
const max_title_decoded = 192;
const max_msg_encoded = 2732;
const max_msg_decoded = 2048;
const max_app = 32;
const max_id = 128;
const max_segment = 32;
const max_depth = 8;

/// Parse `state=working:progress=40:title=QmFzaA==` into a sidebar record, by
/// the Program Status Protocol at revision 0.4.
///
/// Null when the specification says a report is discarded or ignored, and for
/// `state=clear`, which removes a record rather than being one. Null is what
/// leaves the sidebar showing what it inferred, so being strict here never
/// hides a pane, it only refuses to claim a state the report did not cleanly
/// make.
///
/// The last well-formed value of each key is gathered first and the report is
/// then checked as a whole, as the specification requires: every pair is
/// checked before any of it is used, so a report is applied entirely or not
/// at all.
pub fn parse(payload: []const u8) ?sidebar.Reported {
    if (payload.len == 0 or payload.len > max_sequence) return null;

    var state: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var progress: ?[]const u8 = null;
    var app: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var msg: ?[]const u8 = null;
    var id: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, payload, ':');
    while (pairs.next()) |pair| {
        // No `=` is a malformed pair, skipped; the rest still applies.
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = trimBlank(pair[0..eq]);
        const value = trimBlank(pair[eq + 1 ..]);
        // A limit, so the whole report goes, not just the pair.
        if (key.len > max_key) return null;
        if (!validKey(key)) continue;
        if (!validValue(value)) {
            // An id outside the grammar ignores the report. Skipping the pair
            // instead would land the report on the root record, which the
            // specification says a malformed id must never do.
            if (std.mem.eql(u8, key, "id")) return null;
            continue;
        }
        if (std.mem.eql(u8, key, "state")) {
            state = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            kind = value;
        } else if (std.mem.eql(u8, key, "progress")) {
            progress = value;
        } else if (std.mem.eql(u8, key, "app")) {
            app = value;
        } else if (std.mem.eql(u8, key, "title")) {
            title = value;
        } else if (std.mem.eql(u8, key, "msg")) {
            msg = value;
        } else if (std.mem.eql(u8, key, "id")) {
            id = value;
        }
        // Any other key is unknown and ignored: that is how the protocol
        // is extended.
    }

    // A report with no state, or one this tmm does not know, is ignored.
    const named = state orelse return null;
    var out: sidebar.Reported = .{ .state = .idle };
    if (std.mem.eql(u8, named, "working")) {
        out.state = .working;
    } else if (std.mem.eql(u8, named, "blocked")) {
        out.state = .blocked;
    } else if (std.mem.eql(u8, named, "done")) {
        out.state = .done;
    } else if (std.mem.eql(u8, named, "idle")) {
        out.state = .idle;
    } else if (std.mem.eql(u8, named, "error")) {
        out.state = .@"error";
    } else return null; // `clear`, or a state from a newer reporter

    // A valid id addresses a child record. The pane option holds one record,
    // so it is not kept apart, but it is still checked: a bad one discards.
    if (id) |value| if (!validId(value)) return null;
    // Over its limit discards; outside its character set it is only absent.
    // tmm does not draw `app`, so there is nothing to keep.
    if (app) |value| if (value.len > max_app) return null;

    if (title) |value| {
        var buf: [max_title_decoded]u8 = undefined;
        const text = decodeText(value, max_title_encoded, &buf) orelse return null;
        // The row has room for less than a title may carry, so it is cut, on
        // a character boundary rather than through one.
        const n = utf8Fit(text, out.title_buf.len);
        @memcpy(out.title_buf[0..n], text[0..n]);
        out.title_len = @intCast(n);
    }
    // `msg` is not drawn either, but a report whose `msg` does not decode is
    // discarded whole like any other, so it has to be checked.
    if (msg) |value| {
        var buf: [max_msg_decoded]u8 = undefined;
        _ = decodeText(value, max_msg_encoded, &buf) orelse return null;
    }

    // `kind` means something only with `blocked`, and `progress` only with
    // `working` or `blocked`; elsewhere each is ignored. An unknown kind and a
    // progress outside 0-100 are absent, which for progress means
    // indeterminate.
    if (out.state == .blocked) if (kind) |value| {
        if (std.mem.eql(u8, value, "permission")) {
            out.kind = .permission;
        } else if (std.mem.eql(u8, value, "question")) {
            out.kind = .question;
        } else if (std.mem.eql(u8, value, "auth")) {
            out.kind = .auth;
        }
    };
    if (out.state == .working or out.state == .blocked) if (progress) |value| {
        out.progress = parseProgress(value);
    };
    return out;
}

/// A record as it stands now, which is not always as it was written.
///
/// The specification ends `working` and `blocked` records when the program
/// that wrote them exits or the next shell prompt starts, and lets a terminal
/// end `idle` then too; `done` and `error` outlive both, since those are the
/// two a person has not looked at yet. tmm sees neither event directly, but a
/// pane whose own shell runs nothing is at its prompt (`m.atPrompt`). Without
/// this an agent killed by `kill -9` never sends its clear, and its row reads
/// `working` for as long as the pane exists.
pub fn current(payload: []const u8, at_prompt: bool) ?sidebar.Reported {
    const record = parse(payload) orelse return null;
    if (at_prompt) switch (record.state) {
        .working, .blocked, .idle => return null,
        .done, .@"error" => {},
    };
    return record;
}

/// The whitespace the specification means around a key or a value: ASCII
/// space and tab. Anything else blank is outside the value set, which makes
/// the pair malformed rather than something to trim.
fn trimBlank(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

/// The key grammar, `[a-z]+`.
fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (c < 'a' or c > 'z') return false;
    return true;
}

/// The value grammar, `[A-Za-z0-9_.,+/=-]*`.
fn validValue(value: []const u8) bool {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '_', '.', ',', '+', '/', '=', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// The id grammar: one to eight segments of `[A-Za-z0-9_.+-]{1,32}` joined
/// with `/`, at most 128 bytes in all.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id) return false;
    var depth: usize = 0;
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        depth += 1;
        if (depth > max_depth or segment.len == 0 or segment.len > max_segment) return false;
        for (segment) |c| {
            if (std.ascii.isAlphanumeric(c)) continue;
            switch (c) {
                '_', '.', '+', '-' => {},
                else => return false,
            }
        }
    }
    return true;
}

/// An integer from 0 to 100, or null, which the specification reads as
/// indeterminate.
fn parseProgress(value: []const u8) ?u8 {
    if (value.len == 0 or value.len > 3) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u8, value, 10) catch return null;
    return if (n > 100) null else n;
}

/// Decode a base64 text value into `buf`, or null if the report it came from
/// has to be discarded: over the encoded limit (checked before decoding, as
/// the specification requires), not base64, over the decoded limit, not
/// UTF-8, or holding a control character.
///
/// Padding is optional, so both forms are accepted: `base64` pads, and a
/// reporter that trims padding is still sending valid base64. Control
/// characters are refused by code point, so the C1 range (U+0080 to U+009F)
/// is caught as well as C0 and DEL; a byte test would miss C1, whose UTF-8
/// encoding starts with an ordinary 0xC2.
fn decodeText(value: []const u8, max_encoded: usize, buf: []u8) ?[]const u8 {
    if (value.len > max_encoded) return null;
    const decoder = if (std.mem.indexOfScalar(u8, value, '=') != null)
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const len = decoder.calcSizeForSlice(value) catch return null;
    if (len > buf.len) return null;
    decoder.decode(buf[0..len], value) catch return null;
    const text = buf[0..len];
    const view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0x1f or (cp >= 0x7f and cp <= 0x9f)) return null;
    }
    return text;
}

/// How much of `text` fits in `limit` bytes without splitting a character.
fn utf8Fit(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var n = limit;
    while (n > 0 and text[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

test "a reported record survives the pane option intact" {
    const r = parse("state=working:app=claude:title=QmFzaA==").?;
    try std.testing.expectEqual(.working, r.state);
    try std.testing.expectEqualStrings("Bash", r.title());
    try std.testing.expect(r.progress == null);

    const blocked = parse("state=blocked:kind=permission").?;
    try std.testing.expectEqual(.blocked, blocked.state);
    try std.testing.expectEqual(.permission, blocked.kind.?);

    const pct = parse("state=working:progress=40").?;
    try std.testing.expectEqual(@as(?u8, 40), pct.progress);

    // `error` is the state the screen detector has no way to recognise, and
    // the reason the whole payload is carried rather than a bare state word.
    try std.testing.expectEqual(.@"error", parse("state=error").?.state);

    // Whitespace around keys and values is removed; a repeated key takes its
    // last value; a child id is accepted onto the one record.
    try std.testing.expectEqual(.working, parse(" state = idle : state=working ").?.state);
    try std.testing.expectEqual(.done, parse("state=done:id=build/test:msg=QnVpbHQ=").?.state);
}

test "a pane option that says nothing usable is ignored" {
    // Nothing reported at all: the sidebar keeps whatever it inferred.
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("app=claude") == null);
    // `clear` removes a record rather than being a state.
    try std.testing.expect(parse("state=clear") == null);
    // A state from a reporter newer than this tmm.
    try std.testing.expect(parse("state=hibernating") == null);
    // Junk, including a stale option left by something else entirely.
    try std.testing.expect(parse("yes") == null);
    try std.testing.expect(parse("::::") == null);
}

test "a report the specification discards is discarded whole" {
    // A control character in a title, C0 or C1, or text that is not UTF-8.
    // Dropping only the title would still draw the state, which the
    // specification forbids: nothing from a discarded report is applied.
    try std.testing.expect(parse("state=idle:title=Gw==") == null); // ESC
    try std.testing.expect(parse("state=idle:title=woU=") == null); // U+0085
    try std.testing.expect(parse("state=idle:title=/w==") == null); // 0xFF
    // Within the value set but not base64.
    try std.testing.expect(parse("state=idle:title=Q") == null);
    // A msg is held to the same rules even though it is not drawn.
    try std.testing.expect(parse("state=idle:msg=Gw==") == null);
    // A bad id never falls back to the root record.
    try std.testing.expect(parse("state=working:id=a b") == null);
    try std.testing.expect(parse("state=working:id=a//b") == null);
    // Limits: a key over 16 bytes, an app over 32.
    try std.testing.expect(parse("state=idle:abcdefghijklmnopq=1") == null);
    try std.testing.expect(parse("state=idle:app=" ++ "x" ** 33) == null);
}

test "a malformed pair is skipped and the rest of the report applies" {
    // Outside the value set: the pair goes, the state stays.
    try std.testing.expectEqualStrings("", parse("state=idle:title=not base64!").?.title());
    // An upper-case key is not a key.
    try std.testing.expectEqual(.idle, parse("state=idle:STATE=working").?.state);
    // Unpadded base64 is still base64: "Bash" without the padding.
    try std.testing.expectEqualStrings("Bash", parse("state=idle:title=QmFzaA").?.title());
}

test "a long title is cut to the row, not dropped" {
    // "Running the integration tests", 29 bytes: legal (titles go to 192)
    // and longer than the row's 24. It used to vanish entirely, and the test
    // that claimed to cover this passed on the empty string that left.
    const r = parse("state=working:title=UnVubmluZyB0aGUgaW50ZWdyYXRpb24gdGVzdHM=").?;
    try std.testing.expectEqualStrings("Running the integration ", r.title());
    // Nine three-byte characters, 27 bytes: cut on a character boundary,
    // so eight of them, and the cut never splits one.
    const wide = parse("state=idle:title=5pel5pel5pel5pel5pel5pel5pel5pel5pel").?;
    try std.testing.expectEqual(@as(usize, 24), wide.title().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide.title()));
}

test "kind and progress mean something only where the specification says" {
    try std.testing.expect(parse("state=working:kind=permission").?.kind == null);
    try std.testing.expect(parse("state=idle:progress=40").?.progress == null);
    try std.testing.expectEqual(@as(?u8, 40), parse("state=blocked:progress=40").?.progress);
    try std.testing.expect(parse("state=blocked:kind=telepathy").?.kind == null);
    try std.testing.expect(parse("state=working:progress=250").?.progress == null);
    try std.testing.expect(parse("state=working:progress=x").?.progress == null);
    try std.testing.expect(parse("state=working:progress=-1").?.progress == null);
}

test "a record in progress ends when its pane is back at a prompt" {
    // Back at the prompt: work in progress is over, whatever was written.
    try std.testing.expect(current("state=working", true) == null);
    try std.testing.expect(current("state=blocked:kind=permission", true) == null);
    try std.testing.expect(current("state=idle", true) == null);
    // Done and error are the two a person has not seen, so they stay.
    try std.testing.expectEqual(.done, current("state=done", true).?.state);
    try std.testing.expectEqual(.@"error", current("state=error", true).?.state);
    // Still running: nothing changes.
    try std.testing.expectEqual(.working, current("state=working", false).?.state);
}
