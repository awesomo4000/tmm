// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! One terminal region: a pty with a child process on it, a libghostty-vt
//! terminal parsing its output, and a blit of the resulting grid into a
//! libvaxis window.
//!
//! This is the right-hand side of `tmm --shell`: an ordinary shell, in which
//! an ordinary `tmux attach` works. It is not a tmux pane and tmm is not a
//! terminal multiplexer here; the split is tmm drawing two things into one
//! window, so the sidebar costs no second OS window and no second click.
//!
//! Three objects per region, which is the libghostty-vt shape:
//!
//!   terminal      the state
//!   stream        the parser, owning a handler that mutates the state
//!   render_state  the readout, with per-row dirty tracking
//!
//! `Region` must not move once `init` returns: `stream.handler` holds a
//! pointer to `terminal`, and the `write_pty` effect recovers the region from
//! its handler pointer. Allocate it with `create`.

const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const Pty = @import("pty.zig").Pty;

const Allocator = std.mem.Allocator;

/// Printable ASCII as one-byte strings, so the common cell needs no
/// allocation to produce the `[]const u8` grapheme a vaxis cell wants.
const ascii: [128][1]u8 = blk: {
    var table: [128][1]u8 = undefined;
    for (&table, 0..) |*slot, i| slot.* = .{@intCast(i)};
    break :blk table;
};

pub const Region = struct {
    io: std.Io,
    alloc: Allocator,
    pty: Pty,
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    render_state: ghostty.RenderState,

    /// Guards `terminal`, `stream`, and `render_state`. The reader task feeds
    /// the stream; the UI task resizes, renders, and writes input. Both go
    /// through here.
    mutex: std.Io.Mutex = .init,

    /// Set once the child's pty reaches end of stream.
    exited: std.atomic.Value(bool) = .init(false),

    /// False once the pty has been closed. Closing it is what ends the
    /// reader task's blocking read, so shutdown closes before it joins and
    /// `destroy` must not close a second time.
    pty_open: bool = true,

    /// Where to append a line per input event, or null. The slice is not
    /// owned: it comes from the environment, which outlives the region.
    input_log: ?[]const u8 = null,

    /// True while a non-wheel button is down, which the mouse encoder needs
    /// to decide whether a motion off the region is still worth reporting.
    mouse_held: bool = false,

    /// Last cell reported to the child, so a motion inside one cell is not
    /// sent again. Owned here because the encoder only borrows it.
    last_mouse: MouseCell = null,

    cols: u16,
    rows: u16,

    /// Image storage per region. Non-zero so kitty placements survive parsing
    /// even though this cut does not draw them yet.
    const kitty_storage_limit: usize = 16 * 1024 * 1024;

    pub fn create(
        alloc: Allocator,
        io: std.Io,
        argv: []const []const u8,
        cols: u16,
        rows: u16,
        input_log: ?[]const u8,
    ) !*Region {
        const self = try alloc.create(Region);
        errdefer alloc.destroy(self);

        self.* = .{
            .io = io,
            .alloc = alloc,
            .pty = try .spawn(alloc, argv, .{ .cols = cols, .rows = rows }),
            .terminal = undefined,
            .stream = undefined,
            .render_state = .empty,
            .cols = cols,
            .rows = rows,
            .input_log = input_log,
        };
        errdefer self.pty.deinit(io);

        self.terminal = try .init(io, alloc, .{
            .cols = cols,
            .rows = rows,
            .kitty_image_storage_limit = kitty_storage_limit,
        });
        errdefer self.terminal.deinit(alloc);

        // The handler borrows `&self.terminal`, which is why Region is pinned.
        var handler: ghostty.TerminalStream.Handler = .init(&self.terminal);
        handler.effects = .readonly;
        // Terminal responses -- device attributes, cursor position, the kitty
        // graphics and OSC 7501 query replies -- are produced by the library
        // and handed back here. We route them to the child; we do not write
        // them ourselves.
        handler.effects.write_pty = writePty;
        self.stream = .init(.{ .handler = handler, .allocator = alloc });

        return self;
    }

    /// Kill the child and close the pty. Idempotent, and safe to call while
    /// the reader task is blocked in a read: the close is what unblocks it.
    pub fn closePty(self: *Region) void {
        if (!self.pty_open) return;
        self.pty_open = false;
        self.pty.deinit(self.io);
    }

    pub fn destroy(self: *Region) void {
        const alloc = self.alloc;
        self.closePty();
        self.render_state.deinit(alloc);
        self.stream.deinit();
        self.terminal.deinit(alloc);
        alloc.destroy(self);
    }

    /// Recover the region from the handler pointer an effect is called with.
    /// `stream.handler` is a by-value field of the stream, and `stream` is a
    /// by-value field of the region, so two hops land on the region.
    fn fromHandler(handler: *ghostty.TerminalStream.Handler) *Region {
        const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn writePty(handler: *ghostty.TerminalStream.Handler, bytes: []const u8) void {
        const self = fromHandler(handler);
        if (!self.pty_open) return;
        // Called from inside a feed, which already holds the mutex.
        self.pty.write(self.io, bytes) catch {};
    }

    /// Parse `bytes` as output from the child. Called from the reader task.
    pub fn feed(self: *Region, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stream.nextSlice(bytes);
    }

    /// Resize the terminal, the pty, and so the child's idea of its window.
    pub fn resize(self: *Region, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0 or !self.pty_open) return;
        if (cols == self.cols and rows == self.rows) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Through the handler, not the terminal: the handler also emits the
        // in-band size report when the child asked for one (mode 2048).
        try self.stream.handler.resize(.{ .cols = cols, .rows = rows });
        self.cols = cols;
        self.rows = rows;
        try self.pty.setSize(.{ .cols = cols, .rows = rows });
    }

    /// Encode a key press and send it to the child.
    pub fn sendKey(self: *Region, key: vaxis.Key) !void {
        if (!self.pty_open) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const opts: ghostty.input.KeyEncodeOptions = .fromTerminal(&self.terminal);
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var scratch: [4]u8 = undefined;
        ghostty.input.encodeKey(&writer, toKeyEvent(key, &scratch), opts) catch |err| switch (err) {
            // Only a long pre-edit overflows 128 bytes, and vaxis delivers
            // pre-edit text as `text` which we pass through below instead.
            error.WriteFailed => {
                const text = key.text orelse return;
                self.logKey(key, opts, text);
                try self.pty.write(self.io, text);
                return;
            },
        };
        const encoded = writer.buffered();
        // Logged before the length check: a key that encodes to nothing is
        // exactly the case worth seeing.
        self.logKey(key, opts, encoded);
        if (encoded.len == 0) return;
        try self.pty.write(self.io, encoded);
    }

    /// Append one input event and the bytes it produced. Gated on
    /// TMM_INPUT_LOG; free when unset.
    ///
    /// This is the boundary an input bug lives on: what the outer terminal
    /// reported, which mode the child had selected, and what the child was
    /// actually told. Guessing any of the three from a misbehaving program is
    /// what this exists to avoid.
    fn logKey(self: *Region, key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions, sent: []const u8) void {
        if (self.input_log == null) return;
        const mods = modNames(key.mods);
        self.logLine(
            "key cp={d} shifted={?d} base={?d} mods={s} text=\"{f}\" -> key={s} sent=\"{f}\" " ++
                "[cursor_app={} modify_other_2={} kitty={d}]",
            .{
                key.codepoint,
                key.shifted_codepoint,
                key.base_layout_codepoint,
                &mods,
                std.ascii.hexEscape(key.text orelse "", .lower),
                @tagName(toKeyCode(key.codepoint)),
                std.ascii.hexEscape(sent, .lower),
                opts.cursor_key_application,
                opts.modify_other_keys_state_2,
                @as(u5, @bitCast(opts.kitty_flags)),
            },
        );
    }

    /// Held modifiers as a fixed-width set, so log lines stay in columns.
    /// Returned by value; the caller keeps it alive while formatting.
    fn modNames(mods: vaxis.Key.Modifiers) [6]u8 {
        return .{
            if (mods.shift) 'S' else '-',
            if (mods.ctrl) 'C' else '-',
            if (mods.alt) 'A' else '-',
            if (mods.super) 'U' else '-',
            if (mods.caps_lock) 'L' else '-',
            if (mods.num_lock) 'N' else '-',
        };
    }

    fn logLine(self: *Region, comptime fmt: []const u8, args: anytype) void {
        const path = self.input_log orelse return;
        const line = std.fmt.allocPrint(self.alloc, fmt ++ "\n", args) catch return;
        defer self.alloc.free(line);
        var file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch return;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return;
        _ = file.writePositionalAll(self.io, line, st.size) catch {};
    }

    /// The encoder keeps the last reported cell in a slot the caller owns.
    /// Its coordinate type is not exported, so name it through the option
    /// field that takes a pointer to it.
    const MouseCell = @typeInfo(@typeInfo(
        @FieldType(ghostty.input.MouseEncodeOptions, "last_cell"),
    ).optional.child).pointer.child;

    /// Whether this button is a scroll wheel, which the protocol reports as
    /// a press with no matching release.
    fn isWheel(button: vaxis.Mouse.Button) bool {
        return switch (button) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
            else => false,
        };
    }

    /// Translate a vaxis mouse event into the one the encoder wants. `col`
    /// and `row` are cells within the region; the encoder works in pixels,
    /// and `sendMouse` gives it a one-pixel cell so the two coincide.
    fn toMouseEvent(mouse: vaxis.Mouse, col: i16, row: i16) ghostty.input.MouseEncodeEvent {
        return .{
            // vaxis separates a drag from a bare motion. The protocol does
            // not: it tells them apart by whether a button is named.
            .action = switch (mouse.type) {
                .press => .press,
                .release => .release,
                .motion, .drag => .motion,
            },
            // Wheels and the extra buttons are both reported as buttons 4 to
            // 9, but the two enums number them differently, so map by name.
            .button = switch (mouse.button) {
                .none => null,
                .left => .left,
                .middle => .middle,
                .right => .right,
                .wheel_up => .four,
                .wheel_down => .five,
                .wheel_right => .six,
                .wheel_left => .seven,
                .button_8 => .eight,
                .button_9 => .nine,
                .button_10 => .ten,
                .button_11 => .eleven,
            },
            .mods = .{
                .shift = mouse.mods.shift,
                .alt = mouse.mods.alt,
                .ctrl = mouse.mods.ctrl,
            },
            .pos = .{ .x = @floatFromInt(col), .y = @floatFromInt(row) },
        };
    }

    /// Encode a mouse event and send it to the child, in whatever reporting
    /// mode and format the child selected. `col` and `row` are zero-based
    /// cells within the region, not window coordinates. They are signed
    /// because vaxis reports positions off the edge that way, and because
    /// the encoder wants them: a drag off the region is still reported, and
    /// deciding that needs to know the position left the viewport.
    ///
    /// Nothing is written unless the child turned reporting on, so a plain
    /// shell is unaffected while a tmux inside the region gets its clicks.
    pub fn sendMouse(self: *Region, mouse: vaxis.Mouse, col: i16, row: i16) !void {
        if (!self.pty_open) return;

        // A wheel click arrives as a press with no release to match, so it
        // must not leave a button held behind it forever.
        if (!isWheel(mouse.button)) switch (mouse.type) {
            .press => self.mouse_held = true,
            .release => self.mouse_held = false,
            else => {},
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // One pixel per cell. The encoder takes pixels because it serves a
        // GPU surface; a cell one pixel across makes a cell position already
        // a pixel position. libghostty-vt's own encoder tests do the same.
        var opts: ghostty.input.MouseEncodeOptions = .fromTerminal(&self.terminal, .{
            .screen = .{ .width = self.cols, .height = self.rows },
            .cell = .{ .width = 1, .height = 1 },
            .padding = .{},
        });
        opts.any_button_pressed = self.mouse_held or mouse.type == .drag;
        opts.last_cell = &self.last_mouse;

        var buf: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        ghostty.input.encodeMouse(&writer, toMouseEvent(mouse, col, row), opts) catch |err| switch (err) {
            // Nothing encodes to 32 bytes; the longest is SGR with three
            // decimal parameters.
            error.WriteFailed => return,
        };
        const encoded = writer.buffered();
        const mouse_mods = modNames(.{
            .shift = mouse.mods.shift,
            .ctrl = mouse.mods.ctrl,
            .alt = mouse.mods.alt,
        });
        if (self.input_log != null) self.logLine(
            "mouse {s} {s} col={d} row={d} mods={s} -> sent=\"{f}\" [event={s} format={s} held={}]",
            .{
                @tagName(mouse.type),
                @tagName(mouse.button),
                col,
                row,
                &mouse_mods,
                std.ascii.hexEscape(encoded, .lower),
                @tagName(opts.event),
                @tagName(opts.format),
                opts.any_button_pressed,
            },
        );
        if (encoded.len == 0) return;
        try self.pty.write(self.io, encoded);
    }

    /// Draw the region into `win`. `fa` is a per-frame allocator, used only
    /// for graphemes that are not single-byte ASCII.
    pub fn draw(self: *Region, win: vaxis.Window, fa: Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.render_state.update(self.alloc, &self.terminal);
        const state = &self.render_state;
        // libvaxis keeps the previous frame's cells, and only the sidebar is
        // cleared each frame, so an unchanged terminal needs no work at all.
        // Without this the whole region is rewritten on every sidebar refresh.
        if (state.dirty == .false) return;

        const range = state.rowDataRange();
        const row_dirty = state.row_data.items(.dirty);
        const rows_slice = state.row_data.items(.cells);

        var y: u16 = 0;
        for (range.start..range.end) |i| {
            defer y += 1;
            if (y >= win.height) break;
            // vaxis diffs cells itself, so a clean row still has to be written
            // on a full redraw; only a partial update may skip clean rows.
            if (state.dirty == .partial and !row_dirty[i]) continue;
            row_dirty[i] = false;

            const cells = rows_slice[i];
            const raws = cells.items(.raw);
            const styles = cells.items(.style);
            const graphemes = cells.items(.grapheme);

            var x: u16 = 0;
            while (x < win.width) {
                if (x >= raws.len) {
                    win.writeCell(x, y, .{});
                    x += 1;
                    continue;
                }
                const raw = raws[x];
                const style: ghostty.Style = if (raw.hasStyling()) styles[x] else .{};
                const width = raw.gridWidth();
                win.writeCell(x, y, .{
                    .char = .{
                        .grapheme = try grapheme(fa, raw, graphemes[x]),
                        .width = width,
                    },
                    .style = toStyle(style, raw),
                });
                // A wide cell owns the following column; vaxis wants the
                // trailing column left alone rather than overwritten.
                x += width;
            }
        }
        // Rows the child has not produced yet, when the window is taller than
        // the terminal. Only reachable between a window resize and the
        // matching terminal resize.
        while (y < win.height) : (y += 1) {
            for (0..win.width) |x| win.writeCell(@intCast(x), y, .{});
        }
        state.dirty = .false;
    }

    /// Where the child's cursor is within `win`, if it is visible.
    pub fn cursor(self: *Region) ?struct { col: u16, row: u16 } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const c = self.render_state.cursor;
        if (!c.visible) return null;
        const vp = c.viewport orelse return null;
        return .{ .col = vp.x, .row = vp.y };
    }

    fn grapheme(fa: Allocator, raw: ghostty.Cell, cps: []const u21) ![]const u8 {
        if (!raw.hasText()) return " ";
        const cp = raw.codepoint();
        if (raw.content_tag != .codepoint_grapheme) {
            if (cp < 0x80) return &ascii[cp];
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            return fa.dupe(u8, buf[0..n]);
        }
        var out: std.ArrayList(u8) = .empty;
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(fa, buf[0..n]);
        for (cps) |extra| {
            const k = try std.unicode.utf8Encode(extra, &buf);
            try out.appendSlice(fa, buf[0..k]);
        }
        return out.items;
    }

    /// Map a ghostty style to a vaxis one. Colors are mapped by *source*, not
    /// resolved to RGB: an unset color stays `.default` and a palette index
    /// stays an index, so the region inherits the outer terminal's theme the
    /// same way the sidebar does.
    fn toStyle(style: ghostty.Style, raw: ghostty.Cell) vaxis.Cell.Style {
        // A cell can carry its own background without a style, which is how a
        // cleared region with a background color is stored.
        const cell_bg: ?vaxis.Cell.Color = switch (raw.content_tag) {
            .bg_color_palette => .{ .index = raw.content.color_palette.data },
            .bg_color_rgb => .{ .rgb = .{
                raw.content.color_rgb.r,
                raw.content.color_rgb.g,
                raw.content.color_rgb.b,
            } },
            else => null,
        };
        var out: vaxis.Cell.Style = .{
            .fg = toColor(style.fg_color),
            .bg = cell_bg orelse toColor(style.bg_color),
            .ul = toColor(style.underline_color),
            .ul_style = switch (style.flags.underline) {
                .none => .off,
                .single => .single,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            },
            .bold = style.flags.bold,
            .dim = style.flags.faint,
            .italic = style.flags.italic,
            .blink = style.flags.blink,
            .invisible = style.flags.invisible,
            .strikethrough = style.flags.strikethrough,
        };
        // Swap here rather than setting vaxis `reverse`: the outer terminal
        // would otherwise reverse again on top of its own default colors,
        // which is not what the child asked for when it named both colors.
        if (style.flags.inverse) {
            const fg = out.fg;
            out.fg = out.bg;
            out.bg = fg;
        }
        return out;
    }

    fn toColor(c: ghostty.Style.Color) vaxis.Cell.Color {
        return switch (c) {
            .none => .default,
            .palette => |idx| .{ .index = idx },
            .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
        };
    }

    /// Translate a libvaxis key press into the event libghostty-vt encodes
    /// from. vaxis reports a codepoint plus text; ghostty wants a physical key
    /// plus the text it produced, so named keys are mapped and everything
    /// else rides on `utf8`/`unshifted_codepoint`.
    /// Kitty reserves this range for functional keys, which is where vaxis
    /// gets its constants for the arrows, the function keys and the modifier
    /// keys themselves. A codepoint in here is a key, never text.
    const functional_first: u21 = 0xe000;
    const functional_last: u21 = 0xf8ff;

    /// The text a key produced, or the codepoint when the terminal reported
    /// the key without one. `text` is normally set, but a terminal is free to
    /// report a key as a bare `CSI <cp> u` with no text field, and then the
    /// encoder has nothing to send for an ordinary printable key.
    ///
    /// Only when no modifier beyond shift is held: ctrl and alt are encoded
    /// from the key itself, and handing the encoder text as well would change
    /// what it produces.
    fn keyText(key: vaxis.Key, scratch: *[4]u8) []const u8 {
        if (key.text) |text| return text;
        if (key.mods.ctrl or key.mods.alt or key.mods.super) return "";
        const cp = key.codepoint;
        if (cp < 0x20 or cp == 0x7f) return "";
        if (cp >= functional_first and cp <= functional_last) return "";
        const n = std.unicode.utf8Encode(cp, scratch) catch return "";
        return scratch[0..n];
    }

    fn toKeyEvent(key: vaxis.Key, scratch: *[4]u8) ghostty.input.KeyEvent {
        const text = keyText(key, scratch);
        return .{
            .action = .press,
            .key = toKeyCode(key.codepoint),
            .mods = .{
                .shift = key.mods.shift,
                .ctrl = key.mods.ctrl,
                .alt = key.mods.alt,
                .super = key.mods.super,
                .caps_lock = key.mods.caps_lock,
                .num_lock = key.mods.num_lock,
            },
            // vaxis has already applied shift to produce `text`, so the
            // shift that produced it is consumed and must not be encoded
            // again as a modifier.
            .consumed_mods = .{ .shift = key.mods.shift and text.len > 0 },
            .utf8 = text,
            .unshifted_codepoint = @intCast(key.codepoint & 0x1fffff),
        };
    }

    fn toKeyCode(cp: u21) ghostty.input.Key {
        return switch (cp) {
            // Named control keys, which vaxis gives as C0 or kitty codepoints.
            vaxis.Key.tab => .tab,
            vaxis.Key.enter => .enter,
            vaxis.Key.escape => .escape,
            vaxis.Key.space => .space,
            vaxis.Key.backspace => .backspace,
            vaxis.Key.insert => .insert,
            vaxis.Key.delete => .delete,
            vaxis.Key.left => .arrow_left,
            vaxis.Key.right => .arrow_right,
            vaxis.Key.up => .arrow_up,
            vaxis.Key.down => .arrow_down,
            vaxis.Key.page_up => .page_up,
            vaxis.Key.page_down => .page_down,
            vaxis.Key.home => .home,
            vaxis.Key.end => .end,
            vaxis.Key.caps_lock => .caps_lock,
            vaxis.Key.scroll_lock => .scroll_lock,
            vaxis.Key.num_lock => .num_lock,
            vaxis.Key.print_screen => .print_screen,
            vaxis.Key.pause => .pause,
            vaxis.Key.menu => .context_menu,
            vaxis.Key.f1 => .f1,
            vaxis.Key.f2 => .f2,
            vaxis.Key.f3 => .f3,
            vaxis.Key.f4 => .f4,
            vaxis.Key.f5 => .f5,
            vaxis.Key.f6 => .f6,
            vaxis.Key.f7 => .f7,
            vaxis.Key.f8 => .f8,
            vaxis.Key.f9 => .f9,
            vaxis.Key.f10 => .f10,
            vaxis.Key.f11 => .f11,
            vaxis.Key.f12 => .f12,
            // Letters and digits, so ctrl and alt combinations encode from a
            // physical key rather than from text alone.
            'a'...'z' => @enumFromInt(
                @intFromEnum(ghostty.input.Key.key_a) + (cp - 'a'),
            ),
            'A'...'Z' => @enumFromInt(
                @intFromEnum(ghostty.input.Key.key_a) + (cp - 'A'),
            ),
            '0'...'9' => @enumFromInt(
                @intFromEnum(ghostty.input.Key.digit_0) + (cp - '0'),
            ),
            '`', '~' => .backquote,
            '-', '_' => .minus,
            '=', '+' => .equal,
            '[', '{' => .bracket_left,
            ']', '}' => .bracket_right,
            '\\', '|' => .backslash,
            ';', ':' => .semicolon,
            '\'', '"' => .quote,
            ',', '<' => .comma,
            '.', '>' => .period,
            '/', '?' => .slash,
            else => .unidentified,
        };
    }
};

test "key translation names the physical key behind a codepoint" {
    const R = Region;
    try std.testing.expectEqual(ghostty.input.Key.key_a, R.toKeyCode('a'));
    try std.testing.expectEqual(ghostty.input.Key.key_a, R.toKeyCode('A'));
    try std.testing.expectEqual(ghostty.input.Key.key_z, R.toKeyCode('z'));
    try std.testing.expectEqual(ghostty.input.Key.digit_0, R.toKeyCode('0'));
    try std.testing.expectEqual(ghostty.input.Key.digit_9, R.toKeyCode('9'));
    try std.testing.expectEqual(ghostty.input.Key.arrow_up, R.toKeyCode(vaxis.Key.up));
    try std.testing.expectEqual(ghostty.input.Key.f12, R.toKeyCode(vaxis.Key.f12));
    try std.testing.expectEqual(ghostty.input.Key.enter, R.toKeyCode(vaxis.Key.enter));
    // Shift does not change which key is pressed.
    try std.testing.expectEqual(ghostty.input.Key.minus, R.toKeyCode('_'));
    try std.testing.expectEqual(ghostty.input.Key.slash, R.toKeyCode('?'));
}

test "input encoding produces the bytes a child expects" {
    var buf: [64]u8 = undefined;
    const encode = struct {
        fn call(out: []u8, key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions) ![]const u8 {
            var writer: std.Io.Writer = .fixed(out);
            var scratch: [4]u8 = undefined;
            try ghostty.input.encodeKey(&writer, Region.toKeyEvent(key, &scratch), opts);
            return writer.buffered();
        }
    }.call;

    // A plain letter is its own text.
    try std.testing.expectEqualStrings("a", try encode(&buf, .{
        .codepoint = 'a',
        .text = "a",
    }, .{}));
    // ctrl+c is the C0 control, which is how a shell sees an interrupt.
    try std.testing.expectEqualStrings("\x03", try encode(&buf, .{
        .codepoint = 'c',
        .mods = .{ .ctrl = true },
    }, .{}));
    // tmux prefix, so a tmux running in the region is reachable.
    try std.testing.expectEqualStrings("\x02", try encode(&buf, .{
        .codepoint = 'b',
        .mods = .{ .ctrl = true },
    }, .{}));
    // Arrows follow the cursor key mode the child selected, which is the
    // reason the encoder reads options off the terminal rather than guessing.
    try std.testing.expectEqualStrings("\x1b[A", try encode(&buf, .{
        .codepoint = vaxis.Key.up,
    }, .{ .cursor_key_application = false }));
    try std.testing.expectEqualStrings("\x1bOA", try encode(&buf, .{
        .codepoint = vaxis.Key.up,
    }, .{ .cursor_key_application = true }));
}

test "mouse encoding produces the bytes a mouse-aware child expects" {
    var buf: [64]u8 = undefined;
    const Size = @FieldType(ghostty.input.MouseEncodeOptions, "size");
    // The same one-pixel cell `sendMouse` uses, so a cell position is
    // already a pixel position.
    const size: Size = .{
        .screen = .{ .width = 80, .height = 24 },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
    const encode = struct {
        fn call(out: []u8, mouse: vaxis.Mouse, col: i16, row: i16, opts: ghostty.input.MouseEncodeOptions) ![]const u8 {
            var writer: std.Io.Writer = .fixed(out);
            try ghostty.input.encodeMouse(&writer, Region.toMouseEvent(mouse, col, row), opts);
            return writer.buffered();
        }
    }.call;

    const sgr: ghostty.input.MouseEncodeOptions = .{ .event = .any, .format = .sgr, .size = size };

    // A shell that never asked for mouse reporting must see nothing, which
    // is what lets the region forward unconditionally.
    try std.testing.expectEqualStrings("", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    }, 4, 9, .{ .event = .none, .format = .sgr, .size = size }));

    // SGR parameters are one-based, so a click on the region's own first
    // cell must arrive as 1;1 and not 0;0.
    try std.testing.expectEqualStrings("\x1b[<0;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    }, 0, 0, sgr));

    // A release is the lowercase terminator in SGR, which is how a tmux
    // inside the region tells a click from a drag end.
    try std.testing.expectEqualStrings("\x1b[<0;5;10m", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .release,
    }, 4, 9, sgr));

    // The two enums number the buttons differently. Middle must be 1 and
    // right 2 on the wire, whatever ghostty calls them internally.
    try std.testing.expectEqualStrings("\x1b[<1;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .middle,
        .mods = .{},
        .type = .press,
    }, 0, 0, sgr));
    try std.testing.expectEqualStrings("\x1b[<2;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .right,
        .mods = .{},
        .type = .press,
    }, 0, 0, sgr));

    // Scrolling is buttons 64 and 65, which is how a program inside the
    // region scrolls instead of the sidebar.
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }, 0, 0, sgr));
    try std.testing.expectEqualStrings("\x1b[<65;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    }, 0, 0, sgr));

    // A drag is a motion carrying its button: 32 for motion plus the button.
    // vaxis calls this `.drag`; the protocol has no such thing.
    try std.testing.expectEqualStrings("\x1b[<32;3;2M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .drag,
    }, 2, 1, .{ .event = .any, .format = .sgr, .size = size, .any_button_pressed = true }));

    // Modifiers are added to the button code, so ctrl-click is 0 + 16.
    try std.testing.expectEqualStrings("\x1b[<16;1;1M", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{ .ctrl = true },
        .type = .press,
    }, 0, 0, sgr));

    // Normal mode is what most programs select, and it does not want motion.
    try std.testing.expectEqualStrings("", try encode(&buf, .{
        .col = 0,
        .row = 0,
        .button = .none,
        .mods = .{},
        .type = .motion,
    }, 3, 3, .{ .event = .normal, .format = .sgr, .size = size }));
}

test "a wheel press leaves no button held" {
    try std.testing.expect(Region.isWheel(.wheel_up));
    try std.testing.expect(Region.isWheel(.wheel_down));
    try std.testing.expect(!Region.isWheel(.left));
    try std.testing.expect(!Region.isWheel(.none));
}

test "a key reported without text still sends the character" {
    var buf: [64]u8 = undefined;
    const encode = struct {
        fn call(out: []u8, key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions) ![]const u8 {
            var writer: std.Io.Writer = .fixed(out);
            var scratch: [4]u8 = undefined;
            try ghostty.input.encodeKey(&writer, Region.toKeyEvent(key, &scratch), opts);
            return writer.buffered();
        }
    }.call;

    // A terminal may report a key as a bare `CSI <cp> u` with no text field.
    // Without the fallback the encoder has nothing to send and the key is
    // swallowed, which would lose every letter typed into the region.
    try std.testing.expectEqualStrings("x", try encode(&buf, .{ .codepoint = 'x' }, .{}));
    try std.testing.expectEqualStrings("é", try encode(&buf, .{ .codepoint = 'é' }, .{}));

    // A modifier key is not text, however printable its codepoint looks to
    // a UTF-8 encoder. These live in the range kitty reserves for keys.
    for ([_]u21{
        vaxis.Key.left_shift, vaxis.Key.left_control, vaxis.Key.left_alt,
        vaxis.Key.left_super, vaxis.Key.right_shift,  vaxis.Key.f13,
    }) |cp| try std.testing.expectEqualStrings("", try encode(&buf, .{
        .codepoint = cp,
        .mods = .{ .shift = true },
    }, .{}));

    // Nor is the fallback allowed to disturb ctrl and alt, which the encoder
    // produces from the key rather than from text.
    try std.testing.expectEqualStrings("\x06", try encode(&buf, .{
        .codepoint = 'f',
        .mods = .{ .ctrl = true },
    }, .{}));
    // alt is platform-dependent (macos_option_as_alt), so only assert that
    // the fallback did not turn it into plain text.
    try std.testing.expect(!std.mem.eql(u8, "f", try encode(&buf, .{
        .codepoint = 'f',
        .mods = .{ .alt = true },
    }, .{})));

    // Real text still wins over the fallback: vaxis resolves the shifted
    // character and we must send that, not the unshifted codepoint.
    try std.testing.expectEqualStrings("A", try encode(&buf, .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
        .text = "A",
    }, .{}));
}
