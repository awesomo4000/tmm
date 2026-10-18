// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The one key that moves the keyboard between the sidebar and the region.
//!
//! It lives here, and nowhere else, because it is matched in three places --
//! the press, the release, and the presses drained in the same pass -- and a
//! literal repeated three times is a literal that gets changed twice. It is
//! also a choice only the person typing can make -- F12 is an unreasonable
//! reach on a keyboard that puts it behind a function lock -- so
//! `--focus-key` and `TMM_FOCUS_KEY` take anything parseable here.
//!
//! Whatever the key is, tmm consumes it: a program inside the region never
//! sees it, which is why the default is deliberately not a plausible binding
//! (ctrl+b belongs to the tmux that may be running in there). Nesting works
//! the other way round -- an inner tmm given a different key is reachable
//! through an outer one, where two tmms sharing a key are not, because the
//! outer always matches first.

const std = @import("std");
const vaxis = @import("vaxis");

/// What tmm uses when nothing asks for anything else. ctrl+` is close to the
/// home row on every layout, needs no function lock, and is not a tmux prefix
/// or a readline binding; the terminals tmm targets send it as CSI 96;5u
/// rather than as the NUL that ctrl+` means in the legacy encoding.
pub const default_text = "ctrl+`";

/// Checked when `--focus-key` is absent, so the choice can be made once in a
/// shell profile rather than on every invocation.
pub const env_var = "TMM_FOCUS_KEY";

pub const ParseError = error{
    EmptyFocusKey,
    UnknownFocusKey,
    UnknownFocusModifier,
    /// A key that types something, asked for without a modifier that stops it
    /// typing: it would be swallowed every time it was pressed in the region.
    FocusKeyNeedsModifier,
    FocusKeyTooLong,
};

/// Longest accepted spelling, which also bounds the rendered label.
const max_text = 32;

pub const FocusKey = struct {
    codepoint: u21,
    mods: vaxis.Key.Modifiers = .{},
    /// The same physical key as the terminal reports it without the kitty
    /// keyboard protocol, when that differs. A terminal that answers no
    /// progressive-enhancement query sends ctrl+<char> as one C0 byte, and a
    /// byte cannot say which of the keys sharing it was pressed: ctrl+`,
    /// ctrl+@ and ctrl+space are all NUL, which libvaxis reports as ctrl+@.
    /// Matching that too is what keeps the default key working in a terminal
    /// tmm cannot ask for better -- see `legacyAlias`.
    legacy: ?u21 = null,
    /// The canonical spelling, rendered during `parse` so the status line can
    /// show the key that is actually bound rather than the one typed at it.
    label_buf: [max_text]u8 = @splat(0),
    label_len: u8 = 0,

    pub fn label(self: *const FocusKey) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn matches(self: *const FocusKey, key: vaxis.Key) bool {
        if (key.matches(self.codepoint, self.mods)) return true;
        if (self.legacy) |cp| return key.matches(cp, self.mods);
        return false;
    }
};

/// A key tmm can be told to use. `bare` is whether it is usable with no
/// modifier at all: a key that produces text is not, because binding it would
/// take it away from everything typing in the region.
const Named = struct {
    name: []const u8,
    label: []const u8,
    codepoint: u21,
    bare: bool = true,
};

const named = [_]Named{
    .{ .name = "f1", .label = "F1", .codepoint = vaxis.Key.f1 },
    .{ .name = "f2", .label = "F2", .codepoint = vaxis.Key.f2 },
    .{ .name = "f3", .label = "F3", .codepoint = vaxis.Key.f3 },
    .{ .name = "f4", .label = "F4", .codepoint = vaxis.Key.f4 },
    .{ .name = "f5", .label = "F5", .codepoint = vaxis.Key.f5 },
    .{ .name = "f6", .label = "F6", .codepoint = vaxis.Key.f6 },
    .{ .name = "f7", .label = "F7", .codepoint = vaxis.Key.f7 },
    .{ .name = "f8", .label = "F8", .codepoint = vaxis.Key.f8 },
    .{ .name = "f9", .label = "F9", .codepoint = vaxis.Key.f9 },
    .{ .name = "f10", .label = "F10", .codepoint = vaxis.Key.f10 },
    .{ .name = "f11", .label = "F11", .codepoint = vaxis.Key.f11 },
    .{ .name = "f12", .label = "F12", .codepoint = vaxis.Key.f12 },
    .{ .name = "f13", .label = "F13", .codepoint = vaxis.Key.f13 },
    .{ .name = "f14", .label = "F14", .codepoint = vaxis.Key.f14 },
    .{ .name = "f15", .label = "F15", .codepoint = vaxis.Key.f15 },
    .{ .name = "f16", .label = "F16", .codepoint = vaxis.Key.f16 },
    .{ .name = "f17", .label = "F17", .codepoint = vaxis.Key.f17 },
    .{ .name = "f18", .label = "F18", .codepoint = vaxis.Key.f18 },
    .{ .name = "f19", .label = "F19", .codepoint = vaxis.Key.f19 },
    .{ .name = "f20", .label = "F20", .codepoint = vaxis.Key.f20 },
    .{ .name = "insert", .label = "Insert", .codepoint = vaxis.Key.insert },
    .{ .name = "delete", .label = "Delete", .codepoint = vaxis.Key.delete },
    .{ .name = "home", .label = "Home", .codepoint = vaxis.Key.home },
    .{ .name = "end", .label = "End", .codepoint = vaxis.Key.end },
    .{ .name = "page_up", .label = "PgUp", .codepoint = vaxis.Key.page_up },
    .{ .name = "pgup", .label = "PgUp", .codepoint = vaxis.Key.page_up },
    .{ .name = "page_down", .label = "PgDn", .codepoint = vaxis.Key.page_down },
    .{ .name = "pgdn", .label = "PgDn", .codepoint = vaxis.Key.page_down },
    .{ .name = "up", .label = "Up", .codepoint = vaxis.Key.up },
    .{ .name = "down", .label = "Down", .codepoint = vaxis.Key.down },
    .{ .name = "left", .label = "Left", .codepoint = vaxis.Key.left },
    .{ .name = "right", .label = "Right", .codepoint = vaxis.Key.right },
    .{ .name = "print_screen", .label = "PrtSc", .codepoint = vaxis.Key.print_screen },
    .{ .name = "scroll_lock", .label = "ScrLk", .codepoint = vaxis.Key.scroll_lock },
    .{ .name = "pause", .label = "Pause", .codepoint = vaxis.Key.pause },
    .{ .name = "menu", .label = "Menu", .codepoint = vaxis.Key.menu },
    // These four carry text, so each needs a modifier to be bindable. They
    // are listed anyway because ctrl+space and alt+enter are things people
    // reach for, and refusing to parse the name would look like a typo.
    .{ .name = "tab", .label = "Tab", .codepoint = vaxis.Key.tab, .bare = false },
    .{ .name = "enter", .label = "Enter", .codepoint = vaxis.Key.enter, .bare = false },
    .{ .name = "return", .label = "Enter", .codepoint = vaxis.Key.enter, .bare = false },
    .{ .name = "space", .label = "Space", .codepoint = vaxis.Key.space, .bare = false },
    .{ .name = "backspace", .label = "Backspace", .codepoint = vaxis.Key.backspace, .bare = false },
    // Escape types nothing, but a program in the region expects it to arrive:
    // taking it away breaks vi-like editing in there, so it needs a modifier
    // too rather than being quietly allowed because it is not printable.
    .{ .name = "escape", .label = "Esc", .codepoint = vaxis.Key.escape, .bare = false },
    .{ .name = "esc", .label = "Esc", .codepoint = vaxis.Key.escape, .bare = false },
};

/// What libvaxis reports for the single byte a terminal without the kitty
/// keyboard protocol sends for `ctrl+cp`, when that is a different key from
/// `cp` itself.
///
/// Only the bytes libvaxis reports *as a ctrl chord* are aliased. ctrl+i,
/// ctrl+m and ctrl+[ also collapse onto one byte each, but those bytes are
/// Tab, Enter and Escape: binding the focus key to ctrl+[ must not take
/// Escape away from a program in the region, so those return null and the
/// chord simply needs a terminal that can tell them apart.
fn legacyAlias(cp: u21, mods: vaxis.Key.Modifiers) ?u21 {
    if (!mods.ctrl or mods.alt or mods.super) return null;
    if (cp < 0x40 and cp != ' ') return null;
    if (cp > 0x7f) return null;
    const byte: u8 = @as(u8, @intCast(cp)) & 0x1f;
    const reported: u21 = switch (byte) {
        0x00 => '@',
        0x01...0x07, 0x0B...0x0C, 0x0E...0x1A => @as(u21, byte) + 0x60,
        0x0A => 'j',
        // 0x08 backspace, 0x09 tab, 0x0D enter, 0x1B escape, 0x1C-0x1F:
        // keys of their own, not chords. Leave them alone.
        else => return null,
    };
    return if (reported == cp) null else reported;
}

fn applyModifier(token: []const u8, mods: *vaxis.Key.Modifiers) bool {
    const eql = std.mem.eql;
    if (eql(u8, token, "ctrl") or eql(u8, token, "control") or eql(u8, token, "c")) {
        mods.ctrl = true;
    } else if (eql(u8, token, "alt") or eql(u8, token, "opt") or eql(u8, token, "option") or
        eql(u8, token, "meta") or eql(u8, token, "a") or eql(u8, token, "m"))
    {
        mods.alt = true;
    } else if (eql(u8, token, "shift") or eql(u8, token, "s")) {
        mods.shift = true;
    } else if (eql(u8, token, "super") or eql(u8, token, "cmd") or eql(u8, token, "win")) {
        mods.super = true;
    } else return false;
    return true;
}

/// Parse a spelling like `f12`, `ctrl+g`, `C-]`, `alt+page-up`. Modifiers may
/// be separated by `+` or `-`, in any order, and names are case-insensitive;
/// the last token is the key. The returned label is canonical, not the input.
pub fn parse(text: []const u8) ParseError!FocusKey {
    if (text.len > max_text) return error.FocusKeyTooLong;
    var lower_buf: [max_text]u8 = undefined;
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.EmptyFocusKey;
    const lower = std.ascii.lowerString(lower_buf[0..trimmed.len], trimmed);

    var mods: vaxis.Key.Modifiers = .{};
    var rest = lower;
    while (std.mem.indexOfAny(u8, rest, "+-")) |cut| {
        // A separator at either end is the key, not a separator: `ctrl+-` and
        // `ctrl++` both bind punctuation.
        if (cut == 0 or cut + 1 == rest.len) break;
        if (!applyModifier(rest[0..cut], &mods)) {
            // Not a modifier, so this is a key whose own name contains the
            // separator -- `page-up`. Anything else fails the lookup below,
            // which is the error the user needs to see.
            if (std.mem.indexOfAny(u8, rest[cut + 1 ..], "+-") == null) break;
            return error.UnknownFocusModifier;
        }
        rest = rest[cut + 1 ..];
    }
    if (rest.len == 0) return error.EmptyFocusKey;

    // `page-up` and `page_up` are the same key; normalise before the lookup so
    // the table does not need both spellings of every name.
    var key_buf: [max_text]u8 = undefined;
    const key_name = blk: {
        if (rest.len == 1) break :blk rest;
        const n = @min(rest.len, key_buf.len);
        for (rest[0..n], 0..) |c, i| key_buf[i] = if (c == '-') '_' else c;
        break :blk key_buf[0..n];
    };

    var out: FocusKey = .{ .codepoint = 0, .mods = mods };
    var key_label: []const u8 = undefined;
    var bare_ok = false;
    for (named) |entry| {
        if (std.mem.eql(u8, entry.name, key_name)) {
            out.codepoint = entry.codepoint;
            key_label = entry.label;
            bare_ok = entry.bare;
            break;
        }
    } else {
        // One codepoint of its own is the key itself: `ctrl+g`, `C-]`.
        const n = std.unicode.utf8ByteSequenceLength(key_name[0]) catch return error.UnknownFocusKey;
        if (n != key_name.len) return error.UnknownFocusKey;
        out.codepoint = std.unicode.utf8Decode(key_name) catch return error.UnknownFocusKey;
        if (out.codepoint < 0x20) return error.UnknownFocusKey;
        key_label = key_name;
    }

    // Shift alone does not stop a key typing -- it changes what it types --
    // so it does not count as the modifier that makes a text key bindable.
    const held = mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta;
    if (!held and !bare_ok) return error.FocusKeyNeedsModifier;

    out.legacy = legacyAlias(out.codepoint, mods);

    var w = std.Io.Writer.fixed(&out.label_buf);
    if (mods.ctrl) w.writeAll("ctrl+") catch return error.FocusKeyTooLong;
    if (mods.alt) w.writeAll("alt+") catch return error.FocusKeyTooLong;
    if (mods.super) w.writeAll("super+") catch return error.FocusKeyTooLong;
    if (mods.shift) w.writeAll("shift+") catch return error.FocusKeyTooLong;
    w.writeAll(key_label) catch return error.FocusKeyTooLong;
    out.label_len = @intCast(w.end);
    return out;
}

test "the default is ctrl+backtick, spelled as the status line shows it" {
    const key = try parse(default_text);
    try std.testing.expectEqual(@as(u21, '`'), key.codepoint);
    try std.testing.expect(key.mods.eql(.{ .ctrl = true }));
    try std.testing.expectEqualStrings("ctrl+`", key.label());
    // And it is still reachable by name for anyone who wants the old one.
    try std.testing.expectEqual(vaxis.Key.f12, (try parse("f12")).codepoint);
}

test "modifiers parse in either notation and render canonically" {
    for ([_][]const u8{ "ctrl+g", "C-g", "control-G", " ctrl+g " }) |text| {
        const key = try parse(text);
        try std.testing.expectEqual(@as(u21, 'g'), key.codepoint);
        try std.testing.expect(key.mods.ctrl);
        try std.testing.expectEqualStrings("ctrl+g", key.label());
    }
    const combo = try parse("alt+ctrl+space");
    try std.testing.expectEqual(vaxis.Key.space, combo.codepoint);
    try std.testing.expectEqualStrings("ctrl+alt+Space", combo.label());
}

test "a key name may contain the separator, and so may the key" {
    try std.testing.expectEqual(vaxis.Key.page_up, (try parse("page-up")).codepoint);
    try std.testing.expectEqual(vaxis.Key.page_up, (try parse("alt+page_up")).codepoint);
    try std.testing.expectEqual(@as(u21, '-'), (try parse("ctrl+-")).codepoint);
    try std.testing.expectEqual(@as(u21, '+'), (try parse("ctrl++")).codepoint);
}

test "a key that types something is refused without a modifier" {
    try std.testing.expectError(error.FocusKeyNeedsModifier, parse("q"));
    try std.testing.expectError(error.FocusKeyNeedsModifier, parse("shift+q"));
    try std.testing.expectError(error.FocusKeyNeedsModifier, parse("escape"));
    try std.testing.expectError(error.FocusKeyNeedsModifier, parse("tab"));
    // With a modifier the same keys are fine.
    try std.testing.expectEqual(vaxis.Key.escape, (try parse("ctrl+escape")).codepoint);
    try std.testing.expectEqual(vaxis.Key.tab, (try parse("alt+tab")).codepoint);
}

test "nonsense is rejected rather than bound to something surprising" {
    try std.testing.expectError(error.EmptyFocusKey, parse(""));
    try std.testing.expectError(error.EmptyFocusKey, parse("   "));
    try std.testing.expectError(error.UnknownFocusKey, parse("f99"));
    try std.testing.expectError(error.UnknownFocusKey, parse("ctrl+notakey"));
    try std.testing.expectError(error.UnknownFocusModifier, parse("hyperctrl+alt+g"));
    try std.testing.expectError(error.FocusKeyTooLong, parse("ctrl+alt+super+shift+" ++ "x" ** 32));
}

test "the default is reachable in a terminal with no kitty keyboard" {
    // Such a terminal sends NUL, which libvaxis reports as ctrl+@.
    const key = try parse(default_text);
    try std.testing.expect(key.matches(.{ .codepoint = '`', .mods = .{ .ctrl = true } }));
    try std.testing.expect(key.matches(.{ .codepoint = '@', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!key.matches(.{ .codepoint = '`' }));
    // A chord whose byte libvaxis reports as a key of its own is not aliased,
    // so binding it cannot swallow Escape, Tab or Enter.
    try std.testing.expectEqual(@as(?u21, null), (try parse("ctrl+[")).legacy);
    try std.testing.expectEqual(@as(?u21, null), (try parse("ctrl+i")).legacy);
    try std.testing.expectEqual(@as(?u21, null), (try parse("ctrl+m")).legacy);
    // And a chord that already round-trips needs no alias.
    try std.testing.expectEqual(@as(?u21, null), (try parse("ctrl+g")).legacy);
    try std.testing.expectEqual(@as(?u21, '@'), (try parse("ctrl+space")).legacy);
}

test "matching accepts the bound key and nothing else" {
    const key = try parse("ctrl+g");
    try std.testing.expect(key.matches(.{ .codepoint = 'g', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!key.matches(.{ .codepoint = 'g' }));
    try std.testing.expect(!key.matches(.{ .codepoint = 'h', .mods = .{ .ctrl = true } }));
    const f12 = try parse("f12");
    try std.testing.expect(f12.matches(.{ .codepoint = vaxis.Key.f12 }));
    try std.testing.expect(!f12.matches(.{ .codepoint = vaxis.Key.f11 }));
}
