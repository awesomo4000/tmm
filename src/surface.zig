// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! One terminal surface: a libghostty-vt terminal, the parser that drives it,
//! and a blit of the resulting grid into a libvaxis window, plus the input
//! encoding that goes the other way.
//!
//! A surface does not know what is on the other end. Bytes it produces -- the
//! encoding of a key press, and the terminal responses the library generates
//! for queries -- go to a `Sink`. `region.zig` points that at a pty with a
//! shell on it; the compositor points one per tmux pane at `send-keys -H`.
//! That is the whole difference between the two, which is why this is shared:
//! the dirty tracking, the grapheme lifetime rule and the input encoding are
//! subtle enough that a second copy would be a second set of the same bugs.
//!
//! Three objects per surface, which is the libghostty-vt shape:
//!
//!   terminal      the state
//!   stream        the parser, owning a handler that mutates the state
//!   render_state  the readout, with per-row dirty tracking
//!
//! A `Surface` must not move once `init` returns: `stream.handler` holds a
//! pointer to `terminal`, and the write effect recovers the surface from its
//! handler pointer. Initialise it in place, in storage that is already final.

const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");

const Allocator = std.mem.Allocator;

/// Printable ASCII as one-byte strings, so the common cell needs no
/// allocation to produce the `[]const u8` grapheme a vaxis cell wants.
const ascii: [128][1]u8 = blk: {
    var table: [128][1]u8 = undefined;
    for (&table, 0..) |*slot, i| slot.* = .{@intCast(i)};
    break :blk table;
};

/// A cell position within a surface.
pub const Position = struct { col: u16, row: u16 };

/// Whether a key went down or came up. A terminal only reports the second
/// kind when it has been asked to, with the kitty event-types flag, and the
/// encoder drops a release when the program inside did not ask -- so a
/// release can be forwarded unconditionally and will simply encode to
/// nothing for a program that wants presses only.
pub const Action = enum { press, release };

/// One program status record (OSC 7501), as the program last reported it.
///
/// A report replaces its record completely, so a field that is null means
/// the program stopped sending it, not that an older value still stands.
/// Text is owned here: the parser's buffers are only valid for the length of
/// the callback.
pub const Status = struct {
    /// The record's path. Empty for the root record. Segments are joined by
    /// `/`, so `build/test` is a child of `build`.
    id: []const u8,
    state: State,
    kind: ?Kind = null,
    progress: ?u8 = null,
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    /// Bumped on every report, for evicting the least recently updated.
    seq: u64 = 0,

    pub const State = enum { idle, working, done, blocked, @"error" };
    pub const Kind = enum { permission, question, auth };
};

/// The specification requires a terminal to keep at least this many records
/// and to drop the least recently updated past that.
const max_status_records = 256;

/// How an image reaches the outer terminal.
///
/// The surface cannot do this itself: transmitting means writing the pixels
/// down the real tty, which belongs to the display, and only the thread that
/// owns the vaxis instance may touch it. So the owner passes this in and the
/// surface calls it at most once per image.
pub const ImageSink = struct {
    ctx: ?*anyopaque,
    transmit: *const fn (
        ctx: ?*anyopaque,
        bytes: []const u8,
        width: u16,
        height: u16,
        format: vaxis.Image.TransmitFormat,
    ) anyerror!vaxis.Image,

    fn unsupported(_: ?*anyopaque, _: []const u8, _: u16, _: u16, _: vaxis.Image.TransmitFormat) anyerror!vaxis.Image {
        return error.NoGraphicsCapability;
    }

    /// For a display that cannot show images, or has not been asked to.
    pub const none: ImageSink = .{ .ctx = null, .transmit = unsupported };
};

/// Where one image sits on the surface, as the parser last published it.
///
/// A snapshot rather than a live read: the placements live in terminal state
/// behind the parse lock, and the draw must not wait for that lock -- the
/// parser holds it most of the time under load. Only the position is copied,
/// which is a few words per image; the pixels stay where they are and are
/// fetched once, when the image is first transmitted.
pub const ImagePlacement = struct {
    image_id: u32,
    col: u16,
    row: u16,
    z: i32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

/// Where a surface's output goes. `write` must tolerate being called from
/// inside a `feed`, which already holds the surface mutex.
pub const Sink = struct {
    ctx: ?*anyopaque,
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,

    fn discard(_: ?*anyopaque, _: []const u8) void {}

    /// A sink that drops everything, for a surface with nothing on the far
    /// end yet.
    pub const none: Sink = .{ .ctx = null, .write = discard };
};

pub const Surface = struct {
    io: std.Io,
    alloc: Allocator,
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    render_state: ghostty.RenderState,

    /// Where this surface's output goes.
    sink: Sink,

    /// Guards `terminal`, `stream`, and `render_state`. Whoever feeds the
    /// surface and whoever draws it are different tasks; both go through here.
    mutex: std.Io.Mutex = .init,

    /// Backing bytes for the non-ASCII graphemes handed to libvaxis.
    ///
    /// libvaxis does not copy a cell's grapheme: it keeps the slice, and
    /// re-renders unchanged cells from the screen it retains. So the bytes
    /// have to outlive the frame that wrote them, which a per-frame arena
    /// does not. They are reset at the top of each draw that rewrites the
    /// surface, which is exactly when libvaxis stops needing the old ones.
    graphemes: std.heap.ArenaAllocator,

    /// The encoder's view of the terminal's modes, published by the parser
    /// so a keystroke can be encoded without taking the lock.
    ///
    /// The parser holds that lock, and under continuous output it re-acquires
    /// faster than a sleeping waiter can be woken, so anything on the key
    /// path that waits for it inherits the whole backlog: a keypress took
    /// 23ms to reach the child while the same key took 0.2ms on a quiet
    /// terminal. Nothing on this path may wait for the parser.
    ///
    /// Reading a snapshot one chunk old is not a loss of accuracy. The child
    /// has not seen the bytes the parser is working through either, so a key
    /// that arrives mid-parse genuinely precedes them, and encoding it
    /// against the modes in force before that chunk is what the child will
    /// expect. The lock gave the same answer, only slower.
    /// Guards `render_state` alone, and is never held across a parse.
    ///
    /// `mutex` is held for a whole 16KB parse, and `std.Io.Mutex` is an
    /// unfair futex, so anything that waits for it inherits the parser's
    /// duty cycle: an acquisition measured about 10ms under continuous
    /// output against 0.25ms of work behind it. Splitting the state in two
    /// is what fixes that. The parser takes this one only for the update it
    /// publishes, about 0.01ms, so a draw waiting on it waits that long and
    /// not for the parse.
    ///
    /// Lock order is `mutex` then `render` and never the reverse. The draw
    /// takes `render` alone, because it reads no terminal state.
    render: std.Io.Mutex = .init,

    /// Where the images are, refreshed with the render state and read under
    /// the same lock.
    placements: std.ArrayListUnmanaged(ImagePlacement) = .empty,

    /// Program status records (OSC 7501), keyed by id. Owned, including the
    /// text, and guarded by `status_lock` rather than the parse lock so a
    /// reader never waits on the parser.
    status: std.StringArrayHashMapUnmanaged(Status) = .empty,
    status_lock: std.Io.Mutex = .init,
    status_seq: u64 = 0,

    /// How many placements are published, readable without the lock.
    ///
    /// Most frames have no images at all, and the render lock is unfair: a
    /// draw that asks for it every frame can be starved by a parser that
    /// publishes on every chunk of output. Taking it unconditionally cost
    /// the compositor's worst-case keystroke, which went from 0.6ms to
    /// 8.8ms until this check was put in front of it.
    image_count: std.atomic.Value(u32),

    /// Where the draw copies placements to, so it can let go of the lock
    /// before transmitting. Touched only by the thread that draws.
    placement_scratch: std.ArrayListUnmanaged(ImagePlacement) = .empty,

    /// Images already handed to the outer terminal, keyed by the id the child
    /// gave them. Transmitting sends every pixel down the real tty, so it
    /// happens once per image and never once per frame.
    transmitted: std.AutoHashMapUnmanaged(u32, vaxis.Image) = .empty,

    /// The storage generation the cache above was built from. The generation
    /// moves when image data or the placement set changes and deliberately
    /// does not move for a scroll or a resize, which is exactly the
    /// distinction a transmit cache needs.
    images_generation: u64 = 0,

    /// Set when a published update carried a change, cleared by the draw
    /// that consumes it.
    ///
    /// `RenderState.dirty` means "changed since the last update", which was
    /// the same thing as "since the last draw" only while the draw was the
    /// one calling update. Now the parser calls it, and two updates between
    /// two draws would have reported the second as clean and lost the frame.
    needs_draw: std.atomic.Value(bool),

    modes: std.atomic.Value(u32),

    /// Where to append a line per input event, or null. The slice is not
    /// owned: it comes from the environment, which outlives the surface.
    input_log: ?[]const u8 = null,

    /// True while a non-wheel button is down, which the mouse encoder needs
    /// to decide whether a motion off the surface is still worth reporting.
    mouse_held: bool = false,

    /// Last cell reported to the child, so a motion inside one cell is not
    /// sent again. Owned here because the encoder only borrows it.
    last_mouse: MouseCell = null,

    cols: u16,
    rows: u16,

    /// Image storage per surface. Non-zero so kitty placements survive
    /// parsing even though this cut does not draw them yet.
    const kitty_storage_limit: usize = 16 * 1024 * 1024;

    /// Initialise in place. `self` must already live where it will stay.
    pub fn init(
        self: *Surface,
        io: std.Io,
        alloc: Allocator,
        cols: u16,
        rows: u16,
        sink: Sink,
        input_log: ?[]const u8,
    ) !void {
        self.* = .{
            .io = io,
            .alloc = alloc,
            .terminal = undefined,
            .stream = undefined,
            .render_state = .empty,
            .sink = sink,
            .graphemes = .init(alloc),
            .input_log = input_log,
            .cols = cols,
            .rows = rows,
            .modes = .init(0),
            .image_count = .init(0),
            .needs_draw = .init(true),
        };
        errdefer self.graphemes.deinit();

        self.terminal = try .init(io, alloc, .{
            .cols = cols,
            .rows = rows,
            .kitty_image_storage_limit = kitty_storage_limit,
        });
        errdefer self.terminal.deinit(alloc);

        // The handler borrows `&self.terminal`, which is why Surface is pinned.
        var handler: ghostty.TerminalStream.Handler = .init(&self.terminal);
        handler.effects = .readonly;
        // Terminal responses -- device attributes, cursor position, the kitty
        // graphics and OSC 7501 query replies -- are produced by the library
        // and handed back here. We route them to the sink; we do not write
        // them ourselves.
        handler.effects.write_pty = writeOut;
        // Setting this is also what makes the terminal answer the support
        // query, `OSC 7501 ; ?`, through `write_pty`. Left null, a program
        // that asks is told the protocol is unsupported, which is what tmm
        // used to say.
        handler.effects.program_status = onProgramStatus;
        self.stream = .init(.{ .handler = handler, .allocator = alloc });
        // Seeded here so the first keypress reads the terminal's real
        // defaults rather than an all-zero word.
        self.publishModes();
        self.publishRender();
    }

    pub fn deinit(self: *Surface) void {
        self.clearStatus(null);
        self.status.deinit(self.alloc);
        self.placements.deinit(self.alloc);
        self.placement_scratch.deinit(self.alloc);
        self.transmitted.deinit(self.alloc);
        self.render_state.deinit(self.alloc);
        self.graphemes.deinit();
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
    }

    /// Recover the surface from the handler pointer an effect is called with.
    /// `stream.handler` is a by-value field of the stream, and `stream` is a
    /// by-value field of the surface, so two hops land on the surface.
    fn fromHandler(handler: *ghostty.TerminalStream.Handler) *Surface {
        const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    /// A program reported what it is doing (OSC 7501).
    ///
    /// Called from inside a feed, so the parse lock is already held. The
    /// records have their own lock because the display reads them and must
    /// not wait on the parser.
    fn onProgramStatus(
        handler: *ghostty.TerminalStream.Handler,
        report: ghostty.osc.Command.ProgramStatus.Report,
    ) void {
        const self = fromHandler(handler);
        const id = report.readOption(.id) orelse "";

        // `clear` is not a state a record can hold: it removes the addressed
        // record and everything beneath it, or every record when no id is
        // given.
        if (report.state == .clear) {
            if (self.input_log != null) self.logLine("status clear id=\"{s}\"", .{id});
            self.clearStatus(if (id.len == 0) null else id);
            return;
        }

        const state: Status.State = switch (report.state) {
            .idle => .idle,
            .working => .working,
            .done => .done,
            .blocked => .blocked,
            .@"error" => .@"error",
            // Handled above; the parser admits no other values.
            .clear => return,
        };

        var text_buf: [ghostty.osc.program_status.max_msg_bytes]u8 = undefined;
        self.status_lock.lockUncancelable(self.io);
        defer self.status_lock.unlock(self.io);

        self.status_seq += 1;
        var record: Status = .{ .id = "", .state = state, .seq = self.status_seq };
        record.kind = if (report.readOption(.kind)) |k| switch (k) {
            .permission => .permission,
            .question => .question,
            .auth => .auth,
        } else null;
        record.progress = report.readOption(.progress);
        record.app = self.dupeOrNull(report.readOption(.app));
        record.title = self.decodeText(report, .title, &text_buf);
        record.msg = self.decodeText(report, .msg, &text_buf);

        if (self.input_log != null) self.logLine(
            "status id=\"{s}\" state={s} kind={?s} progress={?d} app={?s}",
            .{
                id,
                @tagName(state),
                if (record.kind) |k| @tagName(k) else null,
                record.progress,
                record.app,
            },
        );

        // A report replaces its record completely, so the old one goes
        // entirely rather than being merged into.
        if (self.status.getPtr(id)) |old| {
            const key = old.id;
            self.freeStatusText(old.*);
            old.* = record;
            old.id = key;
            return;
        }
        record.id = self.alloc.dupe(u8, id) catch {
            self.freeStatusText(record);
            return;
        };
        self.status.put(self.alloc, record.id, record) catch {
            self.alloc.free(record.id);
            self.freeStatusText(record);
            return;
        };
        self.evictStatus();
    }

    /// Base64-decode one text field into owned memory, or null when the
    /// program did not send it or it does not decode.
    fn decodeText(
        self: *Surface,
        report: ghostty.osc.Command.ProgramStatus.Report,
        comptime option: ghostty.osc.program_status.Option,
        buf: []u8,
    ) ?[]const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        report.writeText(option, &writer) catch return null;
        const text = writer.buffered();
        if (text.len == 0) return null;
        return self.alloc.dupe(u8, text) catch null;
    }

    fn dupeOrNull(self: *Surface, value: ?[]const u8) ?[]const u8 {
        const v = value orelse return null;
        return self.alloc.dupe(u8, v) catch null;
    }

    fn freeStatusText(self: *Surface, record: Status) void {
        if (record.app) |v| self.alloc.free(v);
        if (record.title) |v| self.alloc.free(v);
        if (record.msg) |v| self.alloc.free(v);
    }

    /// Remove a record and its descendants, or every record when `id` is
    /// null. A descendant is anything whose id starts with `id` followed by a
    /// slash, which is what makes the path a hierarchy.
    fn clearStatus(self: *Surface, id: ?[]const u8) void {
        self.status_lock.lockUncancelable(self.io);
        defer self.status_lock.unlock(self.io);
        var i: usize = 0;
        while (i < self.status.count()) {
            const record = self.status.values()[i];
            const drop = if (id) |prefix|
                std.mem.eql(u8, record.id, prefix) or
                    (record.id.len > prefix.len and
                        std.mem.startsWith(u8, record.id, prefix) and
                        record.id[prefix.len] == '/')
            else
                true;
            if (!drop) {
                i += 1;
                continue;
            }
            self.freeStatusText(record);
            self.alloc.free(record.id);
            _ = self.status.orderedRemoveAt(i);
        }
    }

    /// Past the record cap the least recently updated goes, as the
    /// specification requires. Called with the status lock held.
    fn evictStatus(self: *Surface) void {
        while (self.status.count() > max_status_records) {
            var oldest: usize = 0;
            for (self.status.values(), 0..) |record, i| {
                if (record.seq < self.status.values()[oldest].seq) oldest = i;
            }
            const record = self.status.values()[oldest];
            self.freeStatusText(record);
            self.alloc.free(record.id);
            _ = self.status.orderedRemoveAt(oldest);
        }
    }

    /// Copy out every status record. The caller owns the slice and the text
    /// in it; `freeStatus` releases both.
    pub fn statusRecords(self: *Surface, alloc: Allocator) ![]Status {
        self.status_lock.lockUncancelable(self.io);
        defer self.status_lock.unlock(self.io);
        const out = try alloc.alloc(Status, self.status.count());
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |record| freeStatus(alloc, record);
            alloc.free(out);
        }
        for (self.status.values()) |record| {
            out[n] = .{
                .id = try alloc.dupe(u8, record.id),
                .state = record.state,
                .kind = record.kind,
                .progress = record.progress,
                .seq = record.seq,
            };
            if (record.app) |v| out[n].app = try alloc.dupe(u8, v);
            if (record.title) |v| out[n].title = try alloc.dupe(u8, v);
            if (record.msg) |v| out[n].msg = try alloc.dupe(u8, v);
            n += 1;
        }
        return out;
    }

    pub fn freeStatus(alloc: Allocator, record: Status) void {
        alloc.free(record.id);
        if (record.app) |v| alloc.free(v);
        if (record.title) |v| alloc.free(v);
        if (record.msg) |v| alloc.free(v);
    }

    fn writeOut(handler: *ghostty.TerminalStream.Handler, bytes: []const u8) void {
        const self = fromHandler(handler);
        // Called from inside a feed, which already holds the mutex.
        self.sink.write(self.sink.ctx, bytes);
    }

    pub fn feed(self: *Surface, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stream.nextSlice(bytes);
        // The bytes just parsed are what changes a mode, so this is the only
        // place that has to republish.
        self.publishModes();
        self.publishRender();
    }

    // Two attempts at this lock were measured and reverted. Slicing the parse
    // to release it every 1KB took the draw's wait from 11ms to 23ms, and
    // having the parser sleep 200us whenever a reader was queued changed
    // nothing measurable. `std.Io.Mutex` is a plain futex with no fairness:
    // a woken waiter re-races for it and can lose repeatedly, which is why
    // an acquisition costs about 10ms here while the work costs 0.25ms.
    // Taking it less often is what helps. Not taking it at all would mean
    // the parser publishing render state the way it publishes `modes`, with
    // the buffers double-buffered so a draw never reads the one being
    // written.

    /// Resize the terminal. The owner resizes whatever sits on the other end.
    pub fn resize(self: *Surface, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Through the handler, not the terminal: the handler also emits the
        // in-band size report when the child asked for one (mode 2048).
        try self.stream.handler.resize(.{ .cols = cols, .rows = rows });
        self.cols = cols;
        self.rows = rows;
        self.publishRender();
    }

    /// Encode a key press and send it to the child.
    pub fn sendKey(self: *Surface, key: vaxis.Key, action: Action) void {
        var buf: [128]u8 = undefined;
        var scratch: [4]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        // No lock on this path at all. The modes come from the snapshot the
        // parser publishes, and the write goes straight to the sink.
        const modes: Modes = @bitCast(self.modes.load(.acquire));
        const opts: ghostty.input.KeyEncodeOptions = modes.options();
        const sent: []const u8 = encoded: {
            ghostty.input.encodeKey(&writer, toKeyEvent(key, action, &scratch), opts) catch |err| switch (err) {
                // Only a long pre-edit overflows 128 bytes, and vaxis
                // delivers pre-edit text as `text`, which goes through
                // unencoded instead.
                error.WriteFailed => break :encoded if (action == .press) key.text orelse "" else "",
            };
            break :encoded if (forwards(key, opts)) writer.buffered() else "";
        };

        // Logged before the length check: a key that sends nothing is exactly
        // the case worth seeing.
        self.logKey(key, opts, sent);
        if (sent.len == 0) return;
        self.sink.write(self.sink.ctx, sent);
    }

    /// Whether this key press should reach the child at all.
    ///
    /// A modifier pressed on its own is a key event only to a program that
    /// asked for every key as an escape code. The encoder reports it either
    /// way, from the codepoint, so the gate has to be here: vim turns on
    /// kitty disambiguation alone, which does not include modifier reports,
    /// and then decodes `CSI 57441 u` as text. 57441 is U+E061, which renders
    /// blank, so a bare shift press shows up as a space in the command line.
    fn forwards(key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions) bool {
        return !key.isModifier() or opts.kitty_flags.report_all;
    }

    /// Append one input event and the bytes it produced. Gated on
    /// TMM_INPUT_LOG; free when unset.
    ///
    /// This is the boundary an input bug lives on: what the outer terminal
    /// reported, which mode the child had selected, and what the child was
    /// actually told. Guessing any of the three from a misbehaving program is
    /// what this exists to avoid.
    /// The subset of `KeyEncodeOptions` that comes from terminal state,
    /// narrow enough to publish in one atomic word. `macos_option_as_alt` is
    /// left out on purpose: `fromTerminal` does not set it either.
    const Modes = packed struct(u32) {
        cursor_key_application: bool = false,
        keypad_key_application: bool = false,
        backarrow_key_mode: bool = false,
        ignore_keypad_with_numlock: bool = false,
        alt_esc_prefix: bool = false,
        modify_other_keys_state_2: bool = false,
        kitty_flags: u5 = 0,
        unused: u21 = 0,

        fn from(opts: ghostty.input.KeyEncodeOptions) Modes {
            return .{
                .cursor_key_application = opts.cursor_key_application,
                .keypad_key_application = opts.keypad_key_application,
                .backarrow_key_mode = opts.backarrow_key_mode,
                .ignore_keypad_with_numlock = opts.ignore_keypad_with_numlock,
                .alt_esc_prefix = opts.alt_esc_prefix,
                .modify_other_keys_state_2 = opts.modify_other_keys_state_2,
                .kitty_flags = @bitCast(opts.kitty_flags),
            };
        }

        fn options(self: Modes) ghostty.input.KeyEncodeOptions {
            return .{
                .cursor_key_application = self.cursor_key_application,
                .keypad_key_application = self.keypad_key_application,
                .backarrow_key_mode = self.backarrow_key_mode,
                .ignore_keypad_with_numlock = self.ignore_keypad_with_numlock,
                .alt_esc_prefix = self.alt_esc_prefix,
                .modify_other_keys_state_2 = self.modify_other_keys_state_2,
                .kitty_flags = @bitCast(self.kitty_flags),
            };
        }
    };

    /// Refresh the render state from the terminal. Called with `mutex` held,
    /// by whoever just changed terminal state, so that a draw never has to
    /// take `mutex` to get a current frame.
    fn publishRender(self: *Surface) void {
        self.render.lockUncancelable(self.io);
        defer self.render.unlock(self.io);
        self.render_state.update(self.alloc, &self.terminal) catch return;
        if (self.render_state.dirty != .false) self.needs_draw.store(true, .release);
        self.publishPlacements();
    }

    /// Copy out where each image sits. Called with both locks held, by the
    /// publisher, so the draw can read positions without the parse lock.
    ///
    /// Only placements pinned to the screen are published. A virtual
    /// placement is drawn by the text layout through unicode placeholders and
    /// has no position of its own, and a relative one is anchored to a parent
    /// chain; neither is resolved here yet.
    fn publishPlacements(self: *Surface) void {
        const storage = &self.terminal.screens.active.kitty_images;
        if (!storage.dirty and storage.generation == self.images_generation) return;

        const had_images = self.placements.items.len != 0;
        self.placements.clearRetainingCapacity();
        var it = storage.placements.iterator();
        while (it.next()) |entry| {
            const placement = entry.value_ptr;
            const pin = switch (placement.location) {
                .pin => |pin| pin,
                else => continue,
            };
            const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
            const point = self.terminal.screens.active.pages.pointFromPin(.viewport, pin.*) orelse continue;
            const source = placement.sourceRect(image);
            self.placements.append(self.alloc, .{
                .image_id = entry.key_ptr.image_id,
                .col = @intCast(point.viewport.x),
                .row = @intCast(point.viewport.y),
                .z = placement.z,
                .source_x = source.x,
                .source_y = source.y,
                .source_width = source.width,
                .source_height = source.height,
            }) catch break;
        }
        // A changed generation means the pixels may have changed too, so
        // whatever the outer terminal holds for these ids is stale.
        if (storage.generation != self.images_generation) {
            self.images_generation = storage.generation;
            self.transmitted.clearRetainingCapacity();
        }
        self.image_count.store(@intCast(self.placements.items.len), .release);
        // Only when images are actually involved. `storage.dirty` is set by
        // scrolling, so this runs on nearly every chunk of output, and
        // marking every one of those frames as needing a redraw undid the
        // clean-frame check that the whole draw path rests on: the worst-case
        // keystroke went from 0.6ms to 29ms, which is the parse lock being
        // waited for again by a draw that no longer had any reason to run.
        if (had_images or self.placements.items.len != 0) {
            self.needs_draw.store(true, .release);
        }
    }

    /// Publish the modes the encoder needs. Called with the lock held, by
    /// whoever just changed terminal state.
    fn publishModes(self: *Surface) void {
        const packed_modes: Modes = .from(.fromTerminal(&self.terminal));
        self.modes.store(@bitCast(packed_modes), .release);
    }

    fn logKey(self: *Surface, key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions, sent: []const u8) void {
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

    fn logLine(self: *Surface, comptime fmt: []const u8, args: anytype) void {
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
    pub fn sendMouse(self: *Surface, mouse: vaxis.Mouse, col: i16, row: i16) void {

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
        self.sink.write(self.sink.ctx, encoded);
    }

    /// Draw the region into `win`. `fa` is a per-frame allocator, used only
    /// for graphemes that are not single-byte ASCII.
    pub fn draw(self: *Surface, win: vaxis.Window, sink: ImageSink) !void {
        // libvaxis keeps the previous frame's cells, and only the sidebar is
        // cleared each frame, so an unchanged terminal needs no work at all.
        // Without this the whole region is rewritten on every sidebar refresh.
        // Images are placed every frame whatever the cells did: libvaxis
        // keeps a placement only for the frame it was drawn in, so a frame
        // that skips this one drops the image off the screen.
        if (!self.needs_draw.swap(false, .acq_rel)) {
            self.drawImages(win, sink);
            return;
        }

        // Only the render lock, which the parser holds for one update. The
        // parse lock is never taken here, so how long this waits no longer
        // depends on how much output the child is producing.
        self.render.lockUncancelable(self.io);
        defer self.render.unlock(self.io);
        const state = &self.render_state;

        // Past this point every row is rewritten, so every grapheme libvaxis
        // still holds is about to be replaced and the old bytes are free.
        _ = self.graphemes.reset(.retain_capacity);
        const ga = self.graphemes.allocator();

        const range = state.rowDataRange();
        const row_dirty = state.row_data.items(.dirty);
        const rows_slice = state.row_data.items(.cells);

        var y: u16 = 0;
        for (range.start..range.end) |i| {
            defer y += 1;
            if (y >= win.height) break;
            // Every row is rewritten, clean or not. Skipping a clean row on a
            // partial update would leave libvaxis holding that row's
            // graphemes from an earlier draw, and the reset above has already
            // freed them. libvaxis diffs cells itself, so rewriting a clean
            // row costs a loop and no output.
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
                        .grapheme = try grapheme(ga, raw, graphemes[x]),
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
    /// Place every published image into `win`.
    ///
    /// Transmission happens at most once per image: the bytes go down the
    /// real tty, and an image redrawn per frame would saturate it. The
    /// pixels are read under the parse lock, which is the one place the
    /// display still waits for the parser -- acceptable because it happens
    /// when an image first appears and not while it is on screen.
    fn drawImages(self: *Surface, win: vaxis.Window, sink: ImageSink) void {
        const count = self.image_count.load(.acquire);
        if (count == 0) return;

        // The placements are copied out, not iterated in place and not
        // iterated under the lock.
        //
        // Not in place, because the publisher clears the list and refills it,
        // so an unlocked walk would be reading memory being rewritten. Not
        // under the lock either, because transmitting an image takes the
        // parse lock, and taking that while holding this one deadlocks
        // against the publisher, which takes them the other way round.
        self.placement_scratch.ensureTotalCapacity(self.alloc, count) catch return;
        self.render.lockUncancelable(self.io);
        self.placement_scratch.clearRetainingCapacity();
        const available = @min(self.placements.items.len, self.placement_scratch.capacity);
        self.placement_scratch.appendSliceAssumeCapacity(self.placements.items[0..available]);
        self.render.unlock(self.io);

        for (self.placement_scratch.items) |placement| {
            if (placement.col >= win.width or placement.row >= win.height) continue;
            const image = self.transmit(placement.image_id, sink) orelse continue;
            const child = win.child(.{
                .x_off = placement.col,
                .y_off = placement.row,
                .width = win.width - placement.col,
                .height = win.height - placement.row,
            });
            image.draw(child, .{
                .scale = .none,
                .z_index = placement.z,
                .clip_region = .{
                    .x = @intCast(@min(placement.source_x, std.math.maxInt(u16))),
                    .y = @intCast(@min(placement.source_y, std.math.maxInt(u16))),
                    .width = if (placement.source_width == 0) null else @intCast(@min(placement.source_width, std.math.maxInt(u16))),
                    .height = if (placement.source_height == 0) null else @intCast(@min(placement.source_height, std.math.maxInt(u16))),
                },
            }) catch continue;
        }
    }

    /// The outer terminal's handle for an image, transmitting it the first
    /// time it is asked for. Null when the image cannot be shown: a format
    /// this does not handle, or a display without graphics.
    fn transmit(self: *Surface, image_id: u32, sink: ImageSink) ?vaxis.Image {
        if (self.transmitted.get(image_id)) |cached| return cached;

        // The pixels live in terminal state, so this is the one read that
        // needs the parse lock. Copied out, because the parser may evict the
        // image the moment the lock is released.
        self.mutex.lockUncancelable(self.io);
        const copied: ?struct { bytes: []const u8, width: u16, height: u16, format: vaxis.Image.TransmitFormat } = copy: {
            const storage = &self.terminal.screens.active.kitty_images;
            const image = storage.imageById(image_id) orelse break :copy null;
            const bytes = switch (image.data) {
                .complete => |b| b,
                .pending => break :copy null,
            };
            if (bytes.len == 0) break :copy null;
            // The stored bytes are already decoded; only the channel count
            // has to be told apart. Anything else is left undrawn rather
            // than guessed at.
            const format: vaxis.Image.TransmitFormat = switch (image.format) {
                .rgb => .rgb,
                .rgba => .rgba,
                else => break :copy null,
            };
            const owned = self.alloc.dupe(u8, bytes) catch break :copy null;
            break :copy .{
                .bytes = owned,
                .width = @intCast(@min(image.width, std.math.maxInt(u16))),
                .height = @intCast(@min(image.height, std.math.maxInt(u16))),
                .format = format,
            };
        };
        self.mutex.unlock(self.io);

        const data = copied orelse return null;
        defer self.alloc.free(data.bytes);
        const sent = sink.transmit(sink.ctx, data.bytes, data.width, data.height, data.format) catch return null;
        self.transmitted.put(self.alloc, image_id, sent) catch return sent;
        return sent;
    }

    /// The render lock, not the parse lock: the parser publishes
    /// `render_state` now, so this is shared, but a hold here is one update
    /// long rather than one parse long.
    pub fn cursor(self: *Surface) ?Position {
        self.render.lockUncancelable(self.io);
        defer self.render.unlock(self.io);
        const c = self.render_state.cursor;
        if (!c.visible) return null;
        const vp = c.viewport orelse return null;
        return .{ .col = vp.x, .row = vp.y };
    }

    /// The bytes for one cell. `ga` must be the region's own grapheme arena,
    /// not a per-frame one: libvaxis keeps the slice. Single-byte ASCII comes
    /// from a static table and needs no storage at all, which is why the bug
    /// this guards against only ever showed up on box drawing and symbols.
    fn grapheme(ga: Allocator, raw: ghostty.Cell, cps: []const u21) ![]const u8 {
        if (!raw.hasText()) return " ";
        const cp = raw.codepoint();
        if (raw.content_tag != .codepoint_grapheme) {
            if (cp < 0x80) return &ascii[cp];
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            return ga.dupe(u8, buf[0..n]);
        }
        var out: std.ArrayList(u8) = .empty;
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(ga, buf[0..n]);
        for (cps) |extra| {
            const k = try std.unicode.utf8Encode(extra, &buf);
            try out.appendSlice(ga, buf[0..k]);
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

    fn toKeyEvent(key: vaxis.Key, action: Action, scratch: *[4]u8) ghostty.input.KeyEvent {
        // A release carries no text: it is the key coming up, not the
        // character it produced going in.
        const text = if (action == .press) keyText(key, scratch) else "";
        return .{
            .action = switch (action) {
                .press => .press,
                .release => .release,
            },
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
    const R = Surface;
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
            try ghostty.input.encodeKey(&writer, Surface.toKeyEvent(key, .press, &scratch), opts);
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
            try ghostty.input.encodeMouse(&writer, Surface.toMouseEvent(mouse, col, row), opts);
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
    try std.testing.expect(Surface.isWheel(.wheel_up));
    try std.testing.expect(Surface.isWheel(.wheel_down));
    try std.testing.expect(!Surface.isWheel(.left));
    try std.testing.expect(!Surface.isWheel(.none));
}

test "a key reported without text still sends the character" {
    var buf: [64]u8 = undefined;
    const encode = struct {
        fn call(out: []u8, key: vaxis.Key, opts: ghostty.input.KeyEncodeOptions) ![]const u8 {
            var writer: std.Io.Writer = .fixed(out);
            var scratch: [4]u8 = undefined;
            try ghostty.input.encodeKey(&writer, Surface.toKeyEvent(key, .press, &scratch), opts);
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

test "a release is encoded only for a program that asked for event types" {
    const encode = struct {
        fn call(out: []u8, key: vaxis.Key, action: Action, opts: ghostty.input.KeyEncodeOptions) ![]const u8 {
            var writer: std.Io.Writer = .fixed(out);
            var scratch: [4]u8 = undefined;
            try ghostty.input.encodeKey(&writer, Surface.toKeyEvent(key, action, &scratch), opts);
            return writer.buffered();
        }
    }.call;
    var buf: [64]u8 = undefined;

    // Disambiguation alone: the terminal may report a release, but the
    // program did not ask, so nothing goes out. This is why a release can be
    // forwarded without checking what the program turned on.
    const presses_only: ghostty.input.KeyEncodeOptions = .{ .kitty_flags = .{ .disambiguate = true } };
    try std.testing.expectEqualStrings("", try encode(&buf, .{ .codepoint = 'a', .text = "a" }, .release, presses_only));
    try std.testing.expectEqualStrings("a", try encode(&buf, .{ .codepoint = 'a', .text = "a" }, .press, presses_only));

    // With event types on, a release is its own report and carries no text.
    const with_events: ghostty.input.KeyEncodeOptions = .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true },
    };
    try std.testing.expectEqualStrings("\x1b[97;1:3u", try encode(&buf, .{ .codepoint = 'a', .text = "a" }, .release, with_events));

    // A legacy program, no kitty flags at all: a release is never encoded.
    try std.testing.expectEqualStrings("", try encode(&buf, .{ .codepoint = 'a', .text = "a" }, .release, .{}));
}

test "the support query is answered through the sink" {
    const a = std.testing.allocator;
    var t: std.Io.Threaded = .init(a, .{});
    defer t.deinit();
    const io = t.io();

    // A sink that keeps what the terminal hands back, which is where a reply
    // to a query goes.
    const Recorder = struct {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, buf.len - len);
            @memcpy(buf[len..][0..n], bytes[0..n]);
            len += n;
        }
    };
    Recorder.len = 0;

    const self = try a.create(Surface);
    defer a.destroy(self);
    try self.init(io, a, 20, 5, .{ .ctx = null, .write = Recorder.write }, null);
    defer self.deinit();

    self.feed("\x1b]7501;?\x1b\\");
    const reply = Recorder.buf[0..Recorder.len];
    try std.testing.expect(std.mem.indexOf(u8, reply, "7501") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "states=") != null);
}

test "program status records follow the OSC 7501 rules" {
    const a = std.testing.allocator;
    var t: std.Io.Threaded = .init(a, .{});
    defer t.deinit();
    const io = t.io();

    const self = try a.create(Surface);
    defer a.destroy(self);
    try self.init(io, a, 20, 5, .none, null);
    defer self.deinit();

    // A report with no id addresses the root record.
    self.feed("\x1b]7501;state=working:progress=40:app=cargo\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer {
            for (records) |r| Surface.freeStatus(a, r);
            a.free(records);
        }
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqualStrings("", records[0].id);
        try std.testing.expectEqual(Status.State.working, records[0].state);
        try std.testing.expectEqual(@as(?u8, 40), records[0].progress);
        try std.testing.expectEqualStrings("cargo", records[0].app.?);
    }

    // A report replaces its record completely: progress and app are gone
    // because this report does not carry them, not kept from the last one.
    self.feed("\x1b]7501;state=blocked:kind=permission\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer {
            for (records) |r| Surface.freeStatus(a, r);
            a.free(records);
        }
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqual(Status.State.blocked, records[0].state);
        try std.testing.expectEqual(Status.Kind.permission, records[0].kind.?);
        try std.testing.expect(records[0].progress == null);
        try std.testing.expect(records[0].app == null);
    }

    // Children live alongside the root, and a root can be blocked while a
    // child works.
    self.feed("\x1b]7501;state=working:id=deploy\x1b\\");
    self.feed("\x1b]7501;state=working:id=deploy/us-east:progress=40\x1b\\");
    self.feed("\x1b]7501;state=blocked:id=deploy/eu-west:kind=auth\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer {
            for (records) |r| Surface.freeStatus(a, r);
            a.free(records);
        }
        try std.testing.expectEqual(@as(usize, 4), records.len);
    }

    // `clear` with an id removes that record and its descendants, and
    // nothing else.
    self.feed("\x1b]7501;state=clear:id=deploy\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer {
            for (records) |r| Surface.freeStatus(a, r);
            a.free(records);
        }
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqualStrings("", records[0].id);
    }

    // Base64 text decodes, and is owned here rather than borrowed from the
    // parser, whose buffer is only valid during the callback.
    self.feed("\x1b]7501;state=done:id=build:msg=aGVsbG8gdGhlcmU=\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer {
            for (records) |r| Surface.freeStatus(a, r);
            a.free(records);
        }
        for (records) |r| {
            if (std.mem.eql(u8, r.id, "build")) {
                try std.testing.expectEqualStrings("hello there", r.msg.?);
                break;
            }
        } else return error.RecordMissing;
    }

    // `clear` without an id removes everything.
    self.feed("\x1b]7501;state=clear\x1b\\");
    {
        const records = try self.statusRecords(a);
        defer a.free(records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }
}

test "a modifier pressed alone reaches only a child that asked for every key" {
    const Flags = @FieldType(ghostty.input.KeyEncodeOptions, "kitty_flags");
    const disambiguate: Flags = .{ .disambiguate = true };
    const report_all: Flags = .{ .disambiguate = true, .report_all = true };

    for ([_]u21{
        vaxis.Key.left_shift,  vaxis.Key.left_control,  vaxis.Key.left_alt,
        vaxis.Key.left_super,  vaxis.Key.left_meta,     vaxis.Key.left_hyper,
        vaxis.Key.right_shift, vaxis.Key.right_control,
    }) |cp| {
        const key: vaxis.Key = .{ .codepoint = cp, .mods = .{ .shift = true } };
        // Legacy and modifyOtherKeys children encode nothing for these, so
        // the gate is invisible there; kitty disambiguation is where it bites.
        try std.testing.expect(!Surface.forwards(key, .{ .kitty_flags = disambiguate }));
        try std.testing.expect(Surface.forwards(key, .{ .kitty_flags = report_all }));
    }

    // Everything else is forwarded whatever the child selected, including a
    // key with a modifier held, which is an ordinary key press.
    for ([_]vaxis.Key{
        .{ .codepoint = 'a' },
        .{ .codepoint = 'a', .mods = .{ .shift = true }, .text = "A" },
        .{ .codepoint = '1', .shifted_codepoint = '!', .mods = .{ .shift = true }, .text = "!" },
        .{ .codepoint = 'c', .mods = .{ .ctrl = true } },
        .{ .codepoint = vaxis.Key.escape },
        .{ .codepoint = vaxis.Key.up },
    }) |key| {
        try std.testing.expect(Surface.forwards(key, .{ .kitty_flags = disambiguate }));
        try std.testing.expect(Surface.forwards(key, .{}));
    }
}
