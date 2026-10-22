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

/// Parse `state=working:progress=40:title=QmFzaA==` into a sidebar record.
///
/// Null for anything this cannot make sense of, which is deliberate: an
/// unparsable option should leave the sidebar showing what it inferred rather
/// than claim a state nobody reported. `state=clear` is also null, since it
/// means the record is gone.
pub fn parse(payload: []const u8) ?sidebar.Reported {
    if (payload.len == 0) return null;

    var state: ?@FieldType(sidebar.Reported, "state") = null;
    var out: sidebar.Reported = .{ .state = .idle };

    var options = std.mem.splitScalar(u8, payload, ':');
    while (options.next()) |opt| {
        const eq = std.mem.indexOfScalar(u8, opt, '=') orelse continue;
        const key = opt[0..eq];
        const value = opt[eq + 1 ..];
        if (std.mem.eql(u8, key, "state")) {
            if (std.mem.eql(u8, value, "working")) {
                state = .working;
            } else if (std.mem.eql(u8, value, "blocked")) {
                state = .blocked;
            } else if (std.mem.eql(u8, value, "done")) {
                state = .done;
            } else if (std.mem.eql(u8, value, "idle")) {
                state = .idle;
            } else if (std.mem.eql(u8, value, "error")) {
                state = .@"error";
            } else {
                // `clear`, or a state from a newer reporter than this tmm.
                return null;
            }
        } else if (std.mem.eql(u8, key, "kind")) {
            if (std.mem.eql(u8, value, "permission")) {
                out.kind = .permission;
            } else if (std.mem.eql(u8, value, "question")) {
                out.kind = .question;
            } else if (std.mem.eql(u8, value, "auth")) {
                out.kind = .auth;
            }
            // An unknown kind leaves the state alone rather than dropping the
            // record: the state is the part worth showing.
        } else if (std.mem.eql(u8, key, "progress")) {
            out.progress = std.fmt.parseInt(u8, value, 10) catch null;
            if (out.progress) |p| if (p > 100) {
                out.progress = null;
            };
        } else if (std.mem.eql(u8, key, "title")) {
            // base64, as on the wire. A title that does not decode is
            // dropped on its own, because the state is still worth drawing.
            var buf: [sidebar.Reported.title_max]u8 = undefined;
            const decoded = decodeTitle(value, &buf) orelse continue;
            const n = utf8Fit(decoded, out.title_buf.len);
            @memcpy(out.title_buf[0..n], decoded[0..n]);
            out.title_len = @intCast(n);
        }
        // `id`, `app` and `msg` are carried by the protocol and not drawn on
        // a sidebar row, so they are skipped rather than stored.
    }

    // A record with no state says nothing, whatever else it carried.
    out.state = state orelse return null;
    return out;
}

/// Decode base64 into `buf`, or null if it does not fit or is not base64.
///
/// Both paddings are accepted because both appear in the wild: `base64`
/// pads, and a reporter that trims padding is still sending valid base64 as
/// far as the protocol is concerned.
fn decodeTitle(value: []const u8, buf: []u8) ?[]const u8 {
    const decoder = if (std.mem.indexOfScalar(u8, value, '=') != null)
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const len = decoder.calcSizeForSlice(value) catch return null;
    if (len > buf.len) return null;
    decoder.decode(buf[0..len], value) catch return null;
    const text = buf[0..len];
    // Control characters would be drawn into a sidebar row, and invalid
    // UTF-8 would be handed to the renderer as if it were text.
    for (text) |c| if (c < 0x20 or c == 0x7f) return null;
    if (!std.unicode.utf8ValidateSlice(text)) return null;
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

test "a title is refused rather than drawn when it is not safe text" {
    // Not base64 at all.
    try std.testing.expectEqualStrings("", parse("state=idle:title=not base64!").?.title());
    // Valid base64 of a control character, which would corrupt the row.
    try std.testing.expectEqualStrings("", parse("state=idle:title=Gw==").?.title());
    // Valid base64 that is not valid UTF-8.
    try std.testing.expectEqualStrings("", parse("state=idle:title=/w==").?.title());
    // Unpadded base64 is still base64: "Bash" without the padding.
    try std.testing.expectEqualStrings("Bash", parse("state=idle:title=QmFzaA").?.title());
    // Longer than the row allows, cut on a character boundary rather than
    // through one: five three-byte characters into a buffer that holds 24.
    const long = parse("state=idle:title=5pel5pel5pel5pel5pel5pel5pel5pel5pel").?;
    try std.testing.expect(long.title().len <= 24);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.title()));
    // And a progress a reporter should never have sent.
    try std.testing.expect(parse("state=working:progress=250").?.progress == null);
    try std.testing.expect(parse("state=working:progress=x").?.progress == null);
}
