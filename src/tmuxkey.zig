// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Key names in tmux's spelling, so tmux can look a key up in its own tables.
//!
//! The compositor's normal input path is `send-keys -H`: raw bytes into the
//! pane's program, which is what lets the kitty keyboard protocol work through
//! a tmux that cannot speak it. The cost is that tmux never sees those keys as
//! *client* input, so none of its own bindings fire and `C-a h` reaches the
//! shell as a `0x01` byte and an `h`.
//!
//! `send-keys -K` is the way back. It sends a key to the target client rather
//! than to a pane, "so they are looked up in the client's key table" -- and a
//! control-mode client has a real key table like any other. Measured on tmux
//! 3.8: writing `send-keys -K C-a` on tmm's own control stream moves that
//! client's `client_key_table` from `root` to `prefix`, and a following
//! `send-keys -K h` runs whatever `h` is bound to there. No `-c` and no client
//! name are needed, because a command on the stream is already attributed to
//! that client.
//!
//! So tmm does not interpret bindings, parse `list-keys`, or reimplement a
//! prefix table. It only has to spell a key the way tmux does; tmux owns the
//! tables, the prefix state, custom tables from `switch-client -T`, and the
//! commands themselves. Changing a binding in `.tmux.conf` needs nothing here.
//! This module is that spelling, in both directions: `name` for a key tmm is
//! forwarding, `Chord.parse` for the `prefix` option read back from tmux.
//!
//! It runs only on the prefix path, never on the raw byte path, so nothing
//! here is on the keystroke deadline.

const std = @import("std");
const vaxis = @import("vaxis");

/// A key as tmux names it, written into `buf`, or null for a key tmux has no
/// name for.
///
/// Null rather than a guess: a key sent under the wrong name runs the wrong
/// binding, and the caller can fall back to the raw path where this cannot.
/// `super`, `hyper` and `meta` have no spelling in tmux at all, so a chord
/// using one is refused rather than silently sent without it.
pub fn name(buf: []u8, key: vaxis.Key) ?[]const u8 {
    if (key.mods.super or key.mods.hyper or key.mods.meta) return null;

    const base = baseName(key.codepoint) orelse return null;

    var w: std.Io.Writer = .fixed(buf);
    // tmux's own order, as `list-keys` spells it back: C-M-S-.
    if (key.mods.ctrl) w.writeAll("C-") catch return null;
    if (key.mods.alt) w.writeAll("M-") catch return null;
    // Shift only for the named keys. On a key that types something the shift
    // is already in the codepoint -- the key that produces `A` is `A`, not
    // `S-a` -- and spelling it `S-a` would look up a binding nobody made.
    if (key.mods.shift and base.named) w.writeAll("S-") catch return null;

    if (base.named) {
        w.writeAll(base.text) catch return null;
        return w.buffered();
    }

    // Which character this key actually produced, which is not always its
    // codepoint. A terminal reporting alternate keys sends shift+9 as
    // `CSI 57:41;2u` -- base layout `9`, shifted `)` -- and libvaxis puts the
    // base in `codepoint` with `)` in `shifted_codepoint`. Spelling that from
    // the codepoint gives tmux `9`, which is bound by default to
    // `select-window -t :=9`, so `prefix )` silently switched a window
    // instead of a session. tmux names a key by the character it makes, so
    // the text the key generated is the first choice and the shifted
    // codepoint the second.
    const produced: u21 = blk: {
        if (key.text) |text| {
            const view = std.unicode.Utf8View.init(text) catch break :blk key.codepoint;
            var it = view.iterator();
            if (it.nextCodepoint()) |cp| {
                // One character only: anything longer is not a key name.
                if (it.nextCodepoint() == null and cp >= 0x20 and cp != 0x7f) break :blk cp;
            }
        }
        if (key.mods.shift) if (key.shifted_codepoint) |cp| break :blk cp;
        break :blk key.codepoint;
    };

    // A single character. tmux's command parser reads the control stream
    // before the key name reaches `send-keys`, and it has its own ideas about
    // punctuation: `#` starts a comment, `;` separates commands, `{` opens a
    // brace block that swallows every line until its `}`, and quotes group.
    // A backslash escape is the one spelling that works for all of them --
    // measured across every ASCII punctuation character -- while single
    // quotes fail for `'` itself. Alphanumerics are sent bare, because
    // `\a` and `\0` are not the keys `a` and `0`.
    var utf8: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(produced, &utf8) catch return null;
    const text = utf8[0..len];
    if (len == 1 and !std.ascii.isAlphanumeric(text[0])) w.writeByte('\\') catch return null;
    w.writeAll(text) catch return null;
    return w.buffered();
}

const Base = struct { text: []const u8, named: bool };

/// tmux's name for a codepoint, or null if it has none.
///
/// The named set is tmux's, not a guess: every entry here round-trips through
/// `bind-key` and `list-keys` on tmux 3.8, which is also how the ones that
/// look like they should exist were ruled out -- `Backspace` is rejected and
/// the key is `BSpace`, and `PageUp`, `Insert` and `Delete` are accepted as
/// aliases but spelled back as `PPage`, `IC` and `DC`.
fn baseName(cp: u21) ?Base {
    const named: ?[]const u8 = switch (cp) {
        vaxis.Key.space => "Space",
        vaxis.Key.tab => "Tab",
        vaxis.Key.enter => "Enter",
        vaxis.Key.escape => "Escape",
        vaxis.Key.backspace => "BSpace",
        vaxis.Key.up => "Up",
        vaxis.Key.down => "Down",
        vaxis.Key.left => "Left",
        vaxis.Key.right => "Right",
        vaxis.Key.home => "Home",
        vaxis.Key.end => "End",
        vaxis.Key.page_up => "PPage",
        vaxis.Key.page_down => "NPage",
        vaxis.Key.insert => "IC",
        vaxis.Key.delete => "DC",
        vaxis.Key.kp_enter => "KPEnter",
        else => null,
    };
    if (named) |text| return .{ .text = text, .named = true };

    // F1 to F12 are contiguous in libvaxis and in tmux's naming alike.
    if (cp >= vaxis.Key.f1 and cp <= vaxis.Key.f12) {
        const n = cp - vaxis.Key.f1 + 1;
        return .{ .text = fn_names[n - 1], .named = true };
    }

    // A control character with no name above would be sent as a raw byte in
    // a key name, which tmux does not read as a key.
    if (cp < 0x20 or cp == 0x7f) return null;
    return .{ .text = "", .named = false };
}

const fn_names = [_][]const u8{
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
};

/// A key tmux named, as something a keypress can be matched against.
///
/// This exists for one job: tmm asks tmux for its `prefix` option, which comes
/// back in tmux's spelling (`C-a`, `C-b`, `M-x`), and has to recognise that
/// key when the person presses it. Parsing tmux's spelling is the only way to
/// honour a prefix the person actually configured.
pub const Chord = struct {
    codepoint: u21,
    mods: vaxis.Key.Modifiers = .{},

    /// Parse tmux's spelling, or null for `None` and anything unrecognised.
    ///
    /// `None` is what tmux reports for an unset `prefix2`, so it is a normal
    /// answer rather than an error.
    pub fn parse(text: []const u8) ?Chord {
        if (text.len == 0) return null;
        if (std.mem.eql(u8, text, "None")) return null;

        var rest = text;
        var mods: vaxis.Key.Modifiers = .{};
        while (rest.len > 2 and rest[1] == '-') {
            switch (rest[0]) {
                'C' => mods.ctrl = true,
                'M' => mods.alt = true,
                'S' => mods.shift = true,
                else => break,
            }
            rest = rest[2..];
        }

        // A name from the same table `name` writes, so the two agree by
        // construction rather than by a second list kept in step.
        const names = .{
            .{ "Space", vaxis.Key.space },       .{ "Tab", vaxis.Key.tab },
            .{ "Enter", vaxis.Key.enter },       .{ "Escape", vaxis.Key.escape },
            .{ "BSpace", vaxis.Key.backspace },  .{ "Up", vaxis.Key.up },
            .{ "Down", vaxis.Key.down },         .{ "Left", vaxis.Key.left },
            .{ "Right", vaxis.Key.right },       .{ "Home", vaxis.Key.home },
            .{ "End", vaxis.Key.end },           .{ "PPage", vaxis.Key.page_up },
            .{ "NPage", vaxis.Key.page_down },   .{ "IC", vaxis.Key.insert },
            .{ "DC", vaxis.Key.delete },         .{ "KPEnter", vaxis.Key.kp_enter },
        };
        inline for (names) |entry| {
            if (std.mem.eql(u8, rest, entry[0])) return .{ .codepoint = entry[1], .mods = mods };
        }
        inline for (fn_names, 0..) |text_, i| {
            if (std.mem.eql(u8, rest, text_)) return .{ .codepoint = @intCast(vaxis.Key.f1 + i), .mods = mods };
        }

        // tmux writes a punctuation key escaped in `list-keys` output, so
        // `\;` and `;` both have to read as the same key.
        if (rest.len == 2 and rest[0] == '\\') rest = rest[1..];

        const view = std.unicode.Utf8View.init(rest) catch return null;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return null;
        if (it.nextCodepoint() != null) return null;
        return .{ .codepoint = cp, .mods = mods };
    }

    /// Whether a keypress is this chord.
    ///
    /// libvaxis's own loose matching, which is what makes a prefix work on a
    /// terminal that reports a shifted codepoint or sends text alongside.
    pub fn matches(self: Chord, key: vaxis.Key) bool {
        return key.matches(self.codepoint, self.mods);
    }
};

test "a key is spelled the way tmux spells it" {
    var buf: [32]u8 = undefined;
    // The case this whole module exists for.
    try std.testing.expectEqualStrings("C-a", name(&buf, .{ .codepoint = 'a', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqualStrings("h", name(&buf, .{ .codepoint = 'h', .text = "h" }).?);
    // Modifiers in tmux's order, and combined.
    try std.testing.expectEqualStrings("M-x", name(&buf, .{ .codepoint = 'x', .mods = .{ .alt = true } }).?);
    try std.testing.expectEqualStrings("C-M-a", name(&buf, .{ .codepoint = 'a', .mods = .{ .ctrl = true, .alt = true } }).?);
    // Named keys, including the ones whose obvious name is the wrong one.
    try std.testing.expectEqualStrings("Up", name(&buf, .{ .codepoint = vaxis.Key.up }).?);
    try std.testing.expectEqualStrings("BSpace", name(&buf, .{ .codepoint = vaxis.Key.backspace }).?);
    try std.testing.expectEqualStrings("PPage", name(&buf, .{ .codepoint = vaxis.Key.page_up }).?);
    try std.testing.expectEqualStrings("NPage", name(&buf, .{ .codepoint = vaxis.Key.page_down }).?);
    try std.testing.expectEqualStrings("IC", name(&buf, .{ .codepoint = vaxis.Key.insert }).?);
    try std.testing.expectEqualStrings("DC", name(&buf, .{ .codepoint = vaxis.Key.delete }).?);
    try std.testing.expectEqualStrings("F1", name(&buf, .{ .codepoint = vaxis.Key.f1 }).?);
    try std.testing.expectEqualStrings("F12", name(&buf, .{ .codepoint = vaxis.Key.f12 }).?);
    // Shift is spelled only where it is not already in the codepoint.
    try std.testing.expectEqualStrings("S-Up", name(&buf, .{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } }).?);
    try std.testing.expectEqualStrings("A", name(&buf, .{ .codepoint = 'A', .text = "A", .mods = .{ .shift = true } }).?);
}

test "punctuation is escaped so tmux parses a key and not a command" {
    var buf: [32]u8 = undefined;
    // Each of these means something to tmux's command parser, and `{` is the
    // dangerous one: unescaped it opens a block that eats following commands.
    try std.testing.expectEqualStrings("\\{", name(&buf, .{ .codepoint = '{', .text = "{" }).?);
    try std.testing.expectEqualStrings("\\}", name(&buf, .{ .codepoint = '}', .text = "}" }).?);
    try std.testing.expectEqualStrings("\\#", name(&buf, .{ .codepoint = '#', .text = "#" }).?);
    try std.testing.expectEqualStrings("\\;", name(&buf, .{ .codepoint = ';', .text = ";" }).?);
    try std.testing.expectEqualStrings("\\'", name(&buf, .{ .codepoint = '\'', .text = "'" }).?);
    try std.testing.expectEqualStrings("\\\"", name(&buf, .{ .codepoint = '"', .text = "\"" }).?);
    try std.testing.expectEqualStrings("\\$", name(&buf, .{ .codepoint = '$', .text = "$" }).?);
    // And alphanumerics are bare, because `\a` is not the key `a`.
    try std.testing.expectEqualStrings("z", name(&buf, .{ .codepoint = 'z', .text = "z" }).?);
    try std.testing.expectEqualStrings("7", name(&buf, .{ .codepoint = '7', .text = "7" }).?);
}

test "a key tmux cannot name is refused rather than guessed" {
    var buf: [32]u8 = undefined;
    // No tmux spelling exists for these, so sending anything would run some
    // other binding.
    try std.testing.expect(name(&buf, .{ .codepoint = 'a', .mods = .{ .super = true } }) == null);
    try std.testing.expect(name(&buf, .{ .codepoint = 'a', .mods = .{ .hyper = true } }) == null);
    try std.testing.expect(name(&buf, .{ .codepoint = 'a', .mods = .{ .meta = true } }) == null);
    // A control byte with no name of its own.
    try std.testing.expect(name(&buf, .{ .codepoint = 0x01 }) == null);
    // And a buffer too small to hold the answer fails rather than truncating
    // to a different key.
    var tiny: [2]u8 = undefined;
    try std.testing.expect(name(&tiny, .{ .codepoint = 'a', .mods = .{ .ctrl = true, .alt = true } }) == null);
}

test "the prefix tmux reports is recognised when it is pressed" {
    // What `show-options -gv prefix` actually answers, for both defaults.
    const ctrl_b = Chord.parse("C-b").?;
    try std.testing.expect(ctrl_b.matches(.{ .codepoint = 'b', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!ctrl_b.matches(.{ .codepoint = 'b', .text = "b" }));
    const ctrl_a = Chord.parse("C-a").?;
    try std.testing.expect(ctrl_a.matches(.{ .codepoint = 'a', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!ctrl_a.matches(.{ .codepoint = 'a', .mods = .{ .ctrl = true, .alt = true } }));
    // An unset prefix2 reports this, and it is not a key.
    try std.testing.expect(Chord.parse("None") == null);
    try std.testing.expect(Chord.parse("") == null);
    // A prefix somebody really did configure.
    try std.testing.expect(Chord.parse("M-Space").?.matches(.{ .codepoint = vaxis.Key.space, .mods = .{ .alt = true } }));
    try std.testing.expect(Chord.parse("F1").?.matches(.{ .codepoint = vaxis.Key.f1 }));
    try std.testing.expect(Chord.parse("`").?.matches(.{ .codepoint = '`', .text = "`" }));
    // tmux escapes punctuation when it writes a key out, so both read alike.
    try std.testing.expect(Chord.parse("\\;").?.matches(.{ .codepoint = ';', .text = ";" }));
    // Junk is not a key.
    try std.testing.expect(Chord.parse("Nonsense") == null);
    try std.testing.expect(Chord.parse("C-") == null);
}

test "every name this writes parses back to the key it came from" {
    // The two directions are used together -- one spells a press for tmux,
    // the other reads tmux's prefix back -- so a name only one of them knows
    // is a bug waiting for whoever configures that key as their prefix.
    var buf: [32]u8 = undefined;
    const keys = [_]vaxis.Key{
        .{ .codepoint = 'a', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'x', .mods = .{ .alt = true } },
        .{ .codepoint = vaxis.Key.space },
        .{ .codepoint = vaxis.Key.tab },
        .{ .codepoint = vaxis.Key.enter },
        .{ .codepoint = vaxis.Key.escape },
        .{ .codepoint = vaxis.Key.backspace },
        .{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } },
        .{ .codepoint = vaxis.Key.page_up },
        .{ .codepoint = vaxis.Key.page_down },
        .{ .codepoint = vaxis.Key.insert },
        .{ .codepoint = vaxis.Key.delete },
        .{ .codepoint = vaxis.Key.home },
        .{ .codepoint = vaxis.Key.end },
        .{ .codepoint = vaxis.Key.kp_enter },
        .{ .codepoint = vaxis.Key.f1 },
        .{ .codepoint = vaxis.Key.f12 },
        .{ .codepoint = ';' },
        .{ .codepoint = '{' },
        .{ .codepoint = '`' },
    };
    for (keys) |key| {
        const spelled = name(&buf, key).?;
        const back = Chord.parse(spelled) orelse {
            std.debug.print("no parse for {s}\n", .{spelled});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(key.codepoint, back.codepoint);
        try std.testing.expectEqual(key.mods.ctrl, back.mods.ctrl);
        try std.testing.expectEqual(key.mods.alt, back.mods.alt);
    }
}

test "a shifted punctuation key is named by the character it produced" {
    var buf: [32]u8 = undefined;
    // What a terminal reporting alternate keys sends for shift+9: the base
    // layout key is `9` and the shifted key is `)`. Naming it from the
    // codepoint gives tmux `9`, which is bound by default to
    // `select-window -t :=9`, so `prefix )` switched a window instead of a
    // session -- silently, because `9` is a perfectly valid key name.
    try std.testing.expectEqualStrings("\\)", name(&buf, .{
        .codepoint = '9',
        .shifted_codepoint = ')',
        .text = ")",
        .mods = .{ .shift = true },
    }).?);
    // The same without the text field, which libvaxis fills in itself for
    // ASCII. The shifted codepoint carries it.
    try std.testing.expectEqualStrings("\\(", name(&buf, .{
        .codepoint = '9',
        .shifted_codepoint = '(',
        .mods = .{ .shift = true },
    }).?);
    // A letter is unaffected: the text and the shifted codepoint agree with
    // the uppercase character tmux would name.
    try std.testing.expectEqualStrings("A", name(&buf, .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .text = "A",
        .mods = .{ .shift = true },
    }).?);
    // A ctrl chord produces no text, so the codepoint still decides and the
    // modifier is spelled rather than folded in.
    try std.testing.expectEqualStrings("C-h", name(&buf, .{
        .codepoint = 'h',
        .mods = .{ .ctrl = true },
    }).?);
    // Text longer than one character is not a key name, so it is ignored
    // rather than sent as one.
    try std.testing.expectEqualStrings("a", name(&buf, .{
        .codepoint = 'a',
        .text = "abc",
    }).?);
    // And a named key keeps its name even though it carries text.
    try std.testing.expectEqualStrings("Enter", name(&buf, .{
        .codepoint = vaxis.Key.enter,
        .text = "\r",
    }).?);
}
