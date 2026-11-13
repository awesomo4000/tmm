// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Agent state for terminals: a state machine fed plain observations.
//!
//! It does no I/O, reads no clock and starts no threads. Everything it knows
//! arrives in an `Observation`, the time included, so the same observations
//! always give the same steps, and a test is a list of them. Gathering the
//! evidence is the caller's business -- tmm reads tmux panes -- and the
//! machine says what the evidence means, what changed, and when the screen
//! is worth reading again, which is the expensive part.
//!
//! Each thing watched has a key the caller chooses. `observe` it as often as
//! there is something to say, `acknowledge` a completion someone has looked
//! at, and `sweep` after a pass to forget what was not observed in it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const status = @import("status.zig");
const reported = @import("reported.zig");

/// What an agent is doing, as best the evidence says. `done` is a finished
/// turn nobody has acknowledged yet; once acknowledged it reads `idle`.
/// `error` comes only from an agent's own report.
pub const State = enum { unknown, working, blocked, idle, done, @"error" };

/// Where an inferred state came from.
pub const Source = enum {
    /// Nothing to go on: no agent, or one whose screen is not understood.
    none,
    /// A state word the caller was handed, such as `done:<receipt>`.
    metadata,
    /// The screen, read now or on an earlier observation.
    screen,
};

pub const Screen = struct { text: []const u8, title: []const u8 = "" };

/// Everything the caller knows about one terminal at one moment. Every field
/// but the time may be left out; less evidence only means less certainty.
pub const Observation = struct {
    /// Milliseconds on the caller's clock. Only the time between one
    /// observation of a terminal and the next is used, and time that runs
    /// backwards counts as none passing, so a clock set back costs at most
    /// one observation's worth of waiting. Time that jumps forward is
    /// believed: use a clock that does not, such as a monotonic one.
    at_ms: u64 = 0,
    /// Identity of what runs in the terminal. When it changes, the machine
    /// starts that terminal afresh: a new run has finished nothing yet.
    run: []const u8 = "",
    /// The agent, by name, or empty for none. See `agentCommand` and
    /// `processAgent` for recognising one.
    agent: []const u8 = "",
    /// A state word from the caller, `working`, `blocked`, `idle` or
    /// `done`, optionally followed by `:` and a receipt that tells one
    /// `done` from the next. It outranks the screen.
    state: []const u8 = "",
    /// The agent's own status record, as an OSC 7501 payload. It outranks
    /// everything inferred; see reported.zig.
    report: []const u8 = "",
    /// Whether the terminal's own shell is back at its prompt (`atPrompt`),
    /// which ends a report of work in progress.
    at_prompt: bool = false,
    /// Whether the terminal printed anything since the last observation.
    output: bool = false,
    /// A coarse stamp that changes when the terminal prints, where `output`
    /// cannot be had; null when unknown.
    activity: ?u64 = null,
    /// The screen, when the caller read it. Read it when `needsScreen` says.
    screen: ?Screen = null,
};

/// What the evidence alone says, before completion tracking.
pub const Inferred = struct {
    state: status.State,
    rule: []const u8,
    interrupted: bool = false,
    source: Source,
};

pub const Transition = struct { from: State, to: State, at_ms: u64 };

pub const Step = struct {
    /// The report's state when there is one, else the inferred state with a
    /// completion read as `done` until acknowledged.
    state: State,
    inferred: Inferred,
    report: ?reported.Record,
    /// Completions so far in this run; pass the one shown to `acknowledge`.
    completion: u64,
    /// A completion not yet acknowledged.
    unread: bool,
    /// Set when `state` differs from the previous observation's.
    changed: ?Transition,
};

/// Screen reads owed after the last sign of output. The completion rule
/// needs two idle samples in a row, so a terminal must keep being read for a
/// few observations after it goes quiet, or its working-to-idle transition
/// would never be seen. Three covers working, then idle, then idle.
const reads_after_output: u8 = 3;

const Entry = struct {
    run: []u8,
    agent: []u8,
    track: Track = .{},
    /// The last screen verdict, or null when the screen has not been read
    /// in this run.
    verdict: ?status.Verdict = null,
    /// Screen reads still owed; zero means the terminal has settled.
    reads: u8 = 0,
    /// `activity` when the screen was last read.
    activity: ?u64 = null,
    /// The last step's state, for transitions.
    state: State = .unknown,
    /// The caller's clock at the last observation, and the time elapsed by
    /// it since this run began, which never goes backwards.
    clock: ?u64 = null,
    elapsed: u64 = 0,
    /// The pass this entry was last observed in; see `sweep`.
    pass: u64 = 0,
};

pub const Monitor = struct {
    alloc: Allocator,
    entries: std.StringHashMap(Entry),
    pass: u64 = 0,

    pub fn init(alloc: Allocator) Monitor {
        return .{ .alloc = alloc, .entries = .init(alloc) };
    }

    pub fn deinit(self: *Monitor) void {
        var it = self.entries.iterator();
        while (it.next()) |e| self.free(e.key_ptr.*, e.value_ptr);
        self.entries.deinit();
    }

    fn free(self: *Monitor, key: []const u8, e: *Entry) void {
        self.alloc.free(key);
        self.alloc.free(e.run);
        self.alloc.free(e.agent);
    }

    /// Whether to read the screen for this observation: the agent's screen
    /// is understood, nothing outranks it, and the terminal printed since it
    /// was last read or has not yet settled.
    pub fn needsScreen(self: *const Monitor, key: []const u8, o: Observation) bool {
        if (!readsScreen(o)) return false;
        const e = self.entries.getPtr(key) orelse return true;
        return !sameRun(e, o) or due(e, o);
    }

    /// Take one observation and say where the terminal stands.
    pub fn observe(self: *Monitor, key: []const u8, o: Observation) !Step {
        const e = try self.entry(key, o);
        e.pass = self.pass;
        if (e.clock) |previous| e.elapsed += o.at_ms -| previous;
        e.clock = o.at_ms;
        var inferred = infer(o);
        if (readsScreen(o)) {
            if (o.screen != null or due(e, o)) {
                if (e.verdict == null or printed(e, o)) e.reads = reads_after_output;
                e.reads -|= 1;
                e.verdict = .{ .state = inferred.state, .rule = inferred.rule, .interrupted = inferred.interrupted };
                e.activity = o.activity;
            } else {
                const v = e.verdict.?;
                inferred = .{ .state = v.state, .rule = v.rule, .interrupted = v.interrupted, .source = .screen };
            }
        }
        if (o.agent.len > 0) e.track.observe(
            .{ .state = inferred.state, .rule = inferred.rule, .interrupted = inferred.interrupted },
            if (inferred.source == .metadata) o.state else null,
            e.elapsed,
        );
        const report = if (o.report.len > 0) reported.current(o.report, o.at_prompt) else null;
        const state = effective(e, o, inferred, report);
        const changed: ?Transition = if (state != e.state) .{ .from = e.state, .to = state, .at_ms = o.at_ms } else null;
        e.state = state;
        return .{
            .state = state,
            .inferred = inferred,
            .report = report,
            .completion = e.track.generation,
            .unread = e.track.unread(),
            .changed = changed,
        };
    }

    /// Someone has seen completion `generation` of this terminal's current
    /// run. An older one never clears a newer completion.
    pub fn acknowledge(self: *Monitor, key: []const u8, generation: u64) void {
        const e = self.entries.getPtr(key) orelse return;
        e.track.acknowledge(generation);
    }

    /// Completions so far in this terminal's current run.
    pub fn completion(self: *const Monitor, key: []const u8) u64 {
        const e = self.entries.getPtr(key) orelse return 0;
        return e.track.generation;
    }

    /// Whether this terminal has a completion not yet acknowledged.
    pub fn unread(self: *const Monitor, key: []const u8) bool {
        const e = self.entries.getPtr(key) orelse return false;
        return e.track.unread();
    }

    /// Forget every terminal not observed since the last sweep.
    pub fn sweep(self: *Monitor) void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.alloc);
        var it = self.entries.iterator();
        while (it.next()) |e| if (e.value_ptr.pass != self.pass) {
            stale.append(self.alloc, e.key_ptr.*) catch break;
        };
        for (stale.items) |key| if (self.entries.fetchRemove(key)) |kv| {
            var gone = kv.value;
            self.free(kv.key, &gone);
        };
        self.pass += 1;
    }

    /// The entry for `key`, started afresh when what runs there changed.
    fn entry(self: *Monitor, key: []const u8, o: Observation) !*Entry {
        if (self.entries.getPtr(key)) |e| {
            if (sameRun(e, o)) return e;
            const run = try self.alloc.dupe(u8, o.run);
            errdefer self.alloc.free(run);
            const agent = try self.alloc.dupe(u8, o.agent);
            self.alloc.free(e.run);
            self.alloc.free(e.agent);
            e.* = .{ .run = run, .agent = agent, .state = e.state };
            return e;
        }
        const owned = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned);
        const run = try self.alloc.dupe(u8, o.run);
        errdefer self.alloc.free(run);
        const agent = try self.alloc.dupe(u8, o.agent);
        errdefer self.alloc.free(agent);
        try self.entries.put(owned, .{ .run = run, .agent = agent });
        return self.entries.getPtr(owned).?;
    }
};

/// What one observation says on its own, with no history: the screen is
/// classified if it was read, and counts as unreadable if it was needed and
/// not. For a single look, such as a one-off dump.
pub fn infer(o: Observation) Inferred {
    if (o.agent.len == 0) return .{ .state = .unknown, .rule = "", .source = .none };
    if (o.state.len > 0) return .{ .state = status.metadata(o.state), .rule = "explicit-pane-state", .source = .metadata };
    if (!readsScreen(o)) return .{ .state = .unknown, .rule = "", .source = .none };
    const screen = o.screen orelse return .{ .state = .unknown, .rule = "capture-failed", .source = .screen };
    const v = status.classify(o.agent, screen.text, screen.title);
    return .{ .state = v.state, .rule = v.rule, .interrupted = v.interrupted, .source = .screen };
}

/// Whether the screen is evidence for this observation: the agent is one
/// whose screen is understood, and no state word outranks it.
pub fn readsScreen(o: Observation) bool {
    if (o.state.len > 0) return false;
    return std.mem.eql(u8, o.agent, "codex") or std.mem.eql(u8, o.agent, "claude");
}

fn sameRun(e: *const Entry, o: Observation) bool {
    return std.mem.eql(u8, e.run, o.run) and std.mem.eql(u8, e.agent, o.agent);
}

/// Whether the screen is due a read: never read in this run, printed since,
/// or not yet settled.
fn due(e: *const Entry, o: Observation) bool {
    return e.verdict == null or printed(e, o) or e.reads > 0;
}

/// Whether the terminal printed since its screen was last read. Unknown
/// activity counts as printing: reading too often is the safe mistake.
fn printed(e: *const Entry, o: Observation) bool {
    return o.output or e.activity == null or o.activity == null or e.activity.? != o.activity.?;
}

fn effective(e: *const Entry, o: Observation, inferred: Inferred, report: ?reported.Record) State {
    if (report) |r| return switch (r.state) {
        .idle => .idle,
        .working => .working,
        .done => .done,
        .blocked => .blocked,
        .@"error" => .@"error",
    };
    if (o.agent.len == 0) return .unknown;
    return switch (inferred.state) {
        .unknown => .unknown,
        .working => .working,
        .blocked => .blocked,
        .idle, .done => if (e.track.unread()) .done else .idle,
    };
}

/// How long idle must last after work before the turn counts as complete.
///
/// Agents go idle for a moment between tool calls, and a turn is not over
/// then. Counting idle observations instead made the answer depend on how
/// often the caller looked: two in a row is a second at a 500 ms poll and
/// 33 ms at 60 frames a second. Longer than any pause between tool calls,
/// and short enough that a finished turn still shows promptly.
pub const idle_settle_ms = 1_000;

/// Completion of one run of one agent, from its verdicts in order.
///
/// A turn is complete only when work was seen and then idle followed it for
/// `idle_settle_ms`, or when the agent said `done` with a receipt not seen
/// before. `generation` counts completions; `seen` is the latest one
/// acknowledged.
const Track = struct {
    observed_working: bool = false,
    /// When the current stretch of idle after work began.
    idle_since: ?u64 = null,
    generation: u64 = 0,
    seen: u64 = 0,
    last_done: ?u64 = null,
    pub fn observe(self: *Track, verdict: status.Verdict, receipt: ?[]const u8, at_ms: u64) void {
        if (verdict.interrupted) {
            self.observed_working = false;
            self.idle_since = null;
        }
        switch (verdict.state) {
            .working => {
                self.observed_working = true;
                self.idle_since = null;
            },
            .blocked, .unknown => self.idle_since = null,
            .idle => if (self.observed_working) {
                const since = self.idle_since orelse at_ms;
                self.idle_since = since;
                if (at_ms -| since >= idle_settle_ms) {
                    self.generation += 1;
                    self.observed_working = false;
                    self.idle_since = null;
                }
            },
            .done => {
                const stamp = std.hash.Wyhash.hash(0, receipt orelse "done");
                if (self.observed_working or self.last_done == null or self.last_done.? != stamp) self.generation += 1;
                self.last_done = stamp;
                self.observed_working = false;
                self.idle_since = null;
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
/// Whether a process name is an interactive shell. A login shell is listed by
/// `ps` with a leading `-` (`-bash`), and `comm` may be a full path, so both
/// are stripped before comparing.
pub fn isShellName(command: []const u8) bool {
    var name = std.fs.path.basename(command);
    if (name.len > 0 and name[0] == '-') name = name[1..];
    inline for (.{ "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "yash", "nu", "elvish", "xonsh", "pwsh", "ion", "osh" }) |shell| {
        if (std.mem.eql(u8, name, shell)) return true;
    }
    return false;
}

/// Whether a pane is sitting at its own shell's prompt: its root process is a
/// shell, and nothing runs under it.
///
/// This is how tmm sees the moment the specification ties a program-status
/// record's end to. A terminal drops `working` and `blocked` when the program
/// exits or the next prompt starts (OSC 133 A); tmm never sees a pane's bytes,
/// so it has no OSC 133, but a shell with no children is a shell at its
/// prompt. Structural rather than by the foreground's name, because a
/// reporter running as `sh build.sh` has a shell's name and is very much
/// alive -- it is a child of the pane's shell, so the pane is not at a prompt.
///
/// False whenever the answer is not known, so a missing process table or a
/// root that has already gone never drops a record. A pane whose root is the
/// program itself (`tmux new-window claude`) is never at a prompt either,
/// which keeps that program's record for as long as the pane lives.
pub fn atPrompt(processes: []const Process, root: u32) bool {
    if (root == 0) return false;
    var found = false;
    for (processes) |p| {
        if (p.parent == root) return false;
        if (p.pid == root) {
            if (!isShellName(p.command)) return false;
            found = true;
        }
    }
    return found;
}
test "a pane is at its prompt only when its own shell runs nothing" {
    const a = std.testing.allocator;
    const p = try parseProcesses(a,
        \\10 1 -bash
        \\11 10 claude
        \\20 1 /opt/homebrew/bin/bash
        \\30 1 -zsh
        \\31 30 sh
        \\32 31 make
        \\40 1 claude
        \\50 1 vim
    );
    defer a.free(p);
    // An agent under the shell: not at a prompt.
    try std.testing.expect(!atPrompt(p, 10));
    // A shell with nothing under it, named by full path: at its prompt.
    try std.testing.expect(atPrompt(p, 20));
    // A script running as `sh` under a login zsh: a shell's name, still alive.
    try std.testing.expect(!atPrompt(p, 30));
    // A pane whose root is the program itself is never at a prompt.
    try std.testing.expect(!atPrompt(p, 40));
    try std.testing.expect(!atPrompt(p, 50));
    // Unknown is never "at a prompt": a root that has gone, or no table.
    try std.testing.expect(!atPrompt(p, 99));
    try std.testing.expect(!atPrompt(&.{}, 20));
    try std.testing.expect(!atPrompt(p, 0));
}

test "completion requires observed work and a second of idle; receipts acknowledge separately" {
    var track: Track = .{};
    track.observe(.{ .state = .idle, .rule = "test" }, null, 0);
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .working, .rule = "test" }, null, 500);
    track.observe(.{ .state = .idle, .rule = "test" }, null, 1_000);
    track.observe(.{ .state = .idle, .rule = "test" }, null, 1_500);
    // Idle for half a second is a pause, however many times it was seen.
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .idle, .rule = "test" }, null, 2_000);
    try std.testing.expect(track.unread());
    track.acknowledge(1);
    track.observe(.{ .state = .done, .rule = "test" }, "done:123", 2_500);
    track.acknowledge(1); // an old click cannot erase a newer completion
    try std.testing.expect(track.unread());
    track.acknowledge(2);
    track.observe(.{ .state = .done, .rule = "test" }, "done:123", 3_000);
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .working, .rule = "test" }, null, 3_500);
    track.observe(.{ .state = .idle, .rule = "test", .interrupted = true }, null, 4_000);
    track.observe(.{ .state = .idle, .rule = "test" }, null, 9_000);
    try std.testing.expect(!track.unread());
}

test "a pause between tool calls is not a completion, at any rate of looking" {
    var track: Track = .{};
    track.observe(.{ .state = .working, .rule = "test" }, null, 0);
    // Sixty looks in 900 ms of idle, as a caller drawing every frame makes.
    var at: u64 = 100;
    while (at < 1_000) : (at += 15) track.observe(.{ .state = .idle, .rule = "test" }, null, at);
    track.observe(.{ .state = .working, .rule = "test" }, null, 1_000);
    try std.testing.expect(!track.unread());
    // Blocked restarts the wait: approval is not the end of a turn.
    track.observe(.{ .state = .idle, .rule = "test" }, null, 2_000);
    track.observe(.{ .state = .blocked, .rule = "test" }, null, 2_900);
    track.observe(.{ .state = .idle, .rule = "test" }, null, 3_100);
    try std.testing.expect(!track.unread());
    track.observe(.{ .state = .idle, .rule = "test" }, null, 4_100);
    try std.testing.expect(track.unread());
}

test "Claude activity completes only after idle" {
    const t = std.testing;
    const classify = status.classify;
    const idle = "────────────────\n❯ \n────────────────\nshift+tab to cycle\n";
    var track: Track = .{};
    track.observe(classify("claude", "✶ Thinking…\n" ++ idle, ""), null, 0);
    track.observe(classify("claude", idle, "✳ Claude Code"), null, 500);
    try t.expect(!track.unread());
    track.observe(classify("claude", idle, "✳ Claude Code"), null, 1_500);
    try t.expect(track.unread());
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

const test_screens = struct {
    const idle = "› Ask Codex\n50% context left\n";
    const working = "• Working (2s • esc to interrupt)\n" ++ idle;
    const blocked = "Press enter to confirm or esc to cancel\n";
};

/// A codex terminal at the `tick`th observation, half a second apart as tmm
/// polls, showing `screen` if the caller read it.
fn codex(tick: u64, screen: ?[]const u8) Observation {
    return .{ .at_ms = tick * 500, .run = "r1", .agent = "codex", .activity = 1, .screen = if (screen) |text| .{ .text = text } else null };
}

test "the screen is read until the terminal settles, and again when it prints" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    // Never read: read it.
    try std.testing.expect(mon.needsScreen("t", codex(0, null)));
    _ = try mon.observe("t", codex(0, test_screens.idle));
    // Quiet since: read twice more, then settled.
    try std.testing.expect(mon.needsScreen("t", codex(1, null)));
    _ = try mon.observe("t", codex(1, test_screens.idle));
    try std.testing.expect(mon.needsScreen("t", codex(2, null)));
    _ = try mon.observe("t", codex(2, test_screens.idle));
    try std.testing.expect(!mon.needsScreen("t", codex(3, null)));
    // A settled terminal keeps the verdict it had, without a read.
    const kept = try mon.observe("t", codex(3, null));
    try std.testing.expectEqual(Source.screen, kept.inferred.source);
    try std.testing.expectEqual(status.State.idle, kept.inferred.state);
    // Output, a new activity stamp, or an unknown one, each start reading again.
    var noisy = codex(4, null);
    noisy.output = true;
    try std.testing.expect(mon.needsScreen("t", noisy));
    var stamped = codex(4, null);
    stamped.activity = 2;
    try std.testing.expect(mon.needsScreen("t", stamped));
    var unknown = codex(4, null);
    unknown.activity = null;
    try std.testing.expect(mon.needsScreen("t", unknown));
    // A screen that was needed and not read counts as unreadable.
    const failed = try mon.observe("t", noisy);
    try std.testing.expectEqualStrings("capture-failed", failed.inferred.rule);
}

test "a state word or an agent the screen says nothing about is never read" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var told = codex(0, null);
    told.state = "working:1";
    try std.testing.expect(!mon.needsScreen("t", told));
    const step = try mon.observe("t", told);
    try std.testing.expectEqual(Source.metadata, step.inferred.source);
    try std.testing.expectEqual(State.working, step.state);
    const other: Observation = .{ .run = "r1", .agent = "aider" };
    try std.testing.expect(!mon.needsScreen("u", other));
    try std.testing.expectEqual(State.unknown, (try mon.observe("u", other)).state);
}

test "a turn completes on idle after work, reads done until acknowledged, and says so" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    try std.testing.expectEqual(State.idle, (try mon.observe("t", codex(0, test_screens.idle))).state);
    const work = try mon.observe("t", codex(1, test_screens.working));
    try std.testing.expectEqual(Transition{ .from = .idle, .to = .working, .at_ms = 500 }, work.changed.?);
    // Half a second of idle is not enough: a pause between tool calls.
    const first = try mon.observe("t", codex(2, test_screens.idle));
    try std.testing.expectEqual(State.idle, first.state);
    try std.testing.expect(!(try mon.observe("t", codex(3, test_screens.idle))).unread);
    const settled = try mon.observe("t", codex(4, test_screens.idle));
    try std.testing.expectEqual(State.done, settled.state);
    try std.testing.expectEqual(Transition{ .from = .idle, .to = .done, .at_ms = 2_000 }, settled.changed.?);
    try std.testing.expectEqual(@as(u64, 1), settled.completion);
    // Steady: no transition while nothing changes.
    try std.testing.expect((try mon.observe("t", codex(5, test_screens.idle))).changed == null);
    mon.acknowledge("t", settled.completion);
    try std.testing.expect(!mon.unread("t"));
    try std.testing.expectEqual(State.idle, (try mon.observe("t", codex(6, test_screens.idle))).state);
}

test "an old acknowledgement never clears a newer completion" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var t: u64 = 0;
    for (0..2) |_| for ([_][]const u8{ test_screens.working, test_screens.idle, test_screens.idle, test_screens.idle }) |screen| {
        _ = try mon.observe("t", codex(t, screen));
        t += 1;
    };
    try std.testing.expectEqual(@as(u64, 2), mon.completion("t"));
    mon.acknowledge("t", 1);
    try std.testing.expect(mon.unread("t"));
    mon.acknowledge("t", 2);
    try std.testing.expect(!mon.unread("t"));
}

test "a clock set back neither completes a turn nor stalls one" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    const hour = 3_600_000;
    var o = codex(0, test_screens.working);
    o.at_ms = 10 * hour;
    _ = try mon.observe("t", o);
    o.screen = .{ .text = test_screens.idle };
    o.at_ms += 500;
    _ = try mon.observe("t", o);
    // Set back an hour: no time has passed, as far as the turn is concerned.
    o.at_ms -= hour;
    try std.testing.expect(!(try mon.observe("t", o)).unread);
    // And the wait goes on from there, not from an hour ago.
    o.at_ms += 400;
    try std.testing.expect(!(try mon.observe("t", o)).unread);
    o.at_ms += 600;
    const settled = try mon.observe("t", o);
    try std.testing.expect(settled.unread);
    // Transitions carry the caller's own stamps, set back or not.
    try std.testing.expectEqual(o.at_ms, settled.changed.?.at_ms);
}

test "blocked, interrupted and unknown screens complete nothing" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    for ([_][]const u8{ test_screens.blocked, test_screens.idle, test_screens.idle }, 0..) |screen, t|
        _ = try mon.observe("t", codex(t, screen));
    try std.testing.expect(!mon.unread("t"));
    const interrupted = "■ Conversation interrupted\n" ++ test_screens.idle;
    for ([_][]const u8{ test_screens.working, interrupted, test_screens.idle, test_screens.idle, test_screens.idle, test_screens.idle }, 3..) |screen, t|
        _ = try mon.observe("t", codex(t, screen));
    try std.testing.expect(!mon.unread("t"));
}

test "a done word completes once per receipt" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var o: Observation = .{ .run = "r1", .agent = "claude", .state = "done:1" };
    try std.testing.expectEqual(State.done, (try mon.observe("t", o)).state);
    mon.acknowledge("t", 1);
    try std.testing.expectEqual(State.idle, (try mon.observe("t", o)).state);
    o.state = "done:2";
    const next = try mon.observe("t", o);
    try std.testing.expectEqual(State.done, next.state);
    try std.testing.expectEqual(@as(u64, 2), next.completion);
}

test "the agent's own report outranks the screen, until its shell is back at a prompt" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var o = codex(0, test_screens.idle);
    o.report = "state=blocked:kind=question";
    const step = try mon.observe("t", o);
    try std.testing.expectEqual(State.blocked, step.state);
    try std.testing.expectEqual(status.State.idle, step.inferred.state);
    o.at_prompt = true;
    try std.testing.expectEqual(State.idle, (try mon.observe("t", o)).state);
    o.report = "state=error";
    try std.testing.expectEqual(State.@"error", (try mon.observe("t", o)).state);
    // A report needs no agent: a build script can say it is working.
    const script: Observation = .{ .run = "r1", .report = "state=working:progress=40" };
    const said = try mon.observe("s", script);
    try std.testing.expectEqual(State.working, said.state);
    try std.testing.expectEqual(@as(?u8, 40), said.report.?.progress);
}

test "a new run starts afresh, and a sweep forgets what was not observed" {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    for ([_][]const u8{ test_screens.working, test_screens.idle, test_screens.idle, test_screens.idle }, 0..) |screen, t|
        _ = try mon.observe("t", codex(t, screen));
    try std.testing.expect(mon.unread("t"));
    var next = codex(4, test_screens.idle);
    next.run = "r2";
    const fresh = try mon.observe("t", next);
    try std.testing.expectEqual(@as(u64, 0), fresh.completion);
    try std.testing.expectEqual(Transition{ .from = .done, .to = .idle, .at_ms = 2_000 }, fresh.changed.?);
    mon.sweep();
    _ = try mon.observe("u", codex(5, test_screens.idle));
    mon.sweep();
    try std.testing.expect(mon.entries.get("t") == null);
    try std.testing.expect(mon.entries.get("u") != null);
}

test "one look on its own needs no history" {
    try std.testing.expectEqual(status.State.working, infer(codex(0, test_screens.working)).state);
    try std.testing.expectEqualStrings("capture-failed", infer(codex(0, null)).rule);
    try std.testing.expectEqual(Source.none, infer(.{}).source);
}

/// Random sessions for the invariant tests. The seed is the test runner's:
/// `zig build test --seed 0x...` repeats a run exactly.
const Simulation = struct {
    rng: std.Random,
    at_ms: u64 = 1 << 50,
    run: usize = 0,
    screen: usize = 0,
    activity: u64 = 0,
    agent: []const u8 = "codex",

    const runs = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7" };
    const screens = [_][]const u8{
        test_screens.idle,
        test_screens.working,
        test_screens.blocked,
        "■ Conversation interrupted\n" ++ test_screens.idle,
        "some quiet output\n",
    };
    const words = [_][]const u8{ "working", "idle", "blocked", "done:1", "done:2", "done" };
    const reports = [_][]const u8{ "state=working", "state=blocked:kind=permission", "state=done", "state=error", "state=idle", "state=clear" };

    fn chance(self: *Simulation, n: u32) bool {
        return self.rng.uintLessThan(u32, n) == 0;
    }

    /// The next observation, gathered the way a caller would: the screen is
    /// read when the monitor asks, and now and then when it does not, and a
    /// read sometimes fails.
    fn next(self: *Simulation, mon: *const Monitor) Observation {
        const gaps = [_]u64{ 16, 100, 500, 500, 2_000, 60_000 };
        self.at_ms += gaps[self.rng.uintLessThan(usize, gaps.len)] + self.rng.uintLessThan(u64, 50);
        // The caller's clock set back now and then, by up to a day.
        if (self.chance(40)) self.at_ms -= self.rng.uintAtMost(u64, 86_400_000);
        if (self.chance(150)) self.run = (self.run + 1) % runs.len;
        if (self.chance(4)) self.screen = self.rng.uintLessThan(usize, screens.len);
        const printing = self.screen == 1 or self.chance(5);
        if (printing) self.activity += 1;
        var o: Observation = .{
            .at_ms = self.at_ms,
            .run = runs[self.run],
            .agent = if (self.run == 7) "claude" else self.agent,
            .output = printing,
            .activity = if (self.chance(20)) null else self.activity,
            .at_prompt = self.chance(10),
        };
        if (self.chance(30)) o.state = words[self.rng.uintLessThan(usize, words.len)];
        if (self.chance(20)) o.report = reports[self.rng.uintLessThan(usize, reports.len)];
        if ((mon.needsScreen("t", o) and !self.chance(50)) or self.chance(10))
            o.screen = .{ .text = screens[self.screen] };
        return o;
    }
};

/// Run one random session through a monitor, checking every step, and
/// return a hash of the steps it took.
fn simulate(seed: u64, steps: usize) !u64 {
    var prng = std.Random.DefaultPrng.init(seed);
    var sim: Simulation = .{ .rng = prng.random() };
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var hash = std.hash.Wyhash.init(seed);
    var last: State = .unknown;
    var run: []const u8 = "";
    var completion: u64 = 0;
    // A reference for the completion rule, stated as plainly as it can be:
    // work was seen since the last completion and not interrupted since.
    var saw_work = false;
    var screen_verdict: ?Inferred = null;
    for (0..steps) |_| {
        const o = sim.next(&mon);
        const needed = mon.needsScreen("t", o);
        const step = try mon.observe("t", o);
        if (!std.mem.eql(u8, run, o.run)) {
            run = o.run;
            completion = 0;
            saw_work = false;
            screen_verdict = null;
        }
        // Transitions chain: each starts where the last step ended.
        if (step.changed) |c| {
            try std.testing.expectEqual(last, c.from);
            try std.testing.expectEqual(step.state, c.to);
            try std.testing.expectEqual(o.at_ms, c.at_ms);
        } else try std.testing.expectEqual(last, step.state);
        last = step.state;
        // Completions only count up within a run, and only after work, or
        // on the agent's own word that it is done.
        const inferred = step.inferred;
        if (inferred.interrupted) saw_work = false;
        if (inferred.state == .working) saw_work = true;
        try std.testing.expect(step.completion == completion or step.completion == completion + 1);
        if (step.completion > completion) {
            try std.testing.expect(saw_work or inferred.state == .done);
            saw_work = false;
        }
        if (inferred.state == .done) saw_work = false;
        completion = step.completion;
        try std.testing.expect(!step.unread or step.completion > 0);
        // A terminal the monitor did not need read keeps the verdict its
        // screen last gave, in this run.
        if (readsScreen(o)) {
            if (!needed and o.screen == null) {
                try std.testing.expect(screen_verdict != null);
                try std.testing.expectEqual(screen_verdict.?.state, inferred.state);
                try std.testing.expectEqualStrings(screen_verdict.?.rule, inferred.rule);
            }
            screen_verdict = inferred;
        }
        // The agent's own report outranks everything inferred.
        if (step.report) |r| try std.testing.expectEqualStrings(@tagName(r.state), @tagName(step.state));
        // An acknowledgement of an older completion never clears a newer one.
        if (sim.chance(15)) {
            const seen = sim.rng.uintAtMost(u64, step.completion + 1);
            mon.acknowledge("t", seen);
            if (seen < step.completion) try std.testing.expectEqual(step.unread, mon.unread("t"));
            if (seen >= step.completion) try std.testing.expect(!mon.unread("t"));
        }
        hash.update(std.mem.asBytes(&.{ @backingInt(step.state), step.completion, @intFromBool(step.unread) }));
    }
    return hash.final();
}

test "random sessions keep the invariants, and the same seed takes the same steps" {
    const seed = std.testing.random_seed;
    errdefer std.debug.print("agent state simulation failed; rerun with zig build test --seed 0x{x}\n", .{seed});
    var sessions = std.Random.DefaultPrng.init(seed);
    for (0..200) |_| {
        const session = sessions.random().int(u64);
        const first = try simulate(session, 400);
        try std.testing.expectEqual(first, try simulate(session, 400));
    }
}

/// A stretch of one screen, for a session laid out in time.
const Segment = struct { screen: []const u8, ms: u64 };

/// A session of `turns` turns, as an agent really runs one: work in bursts,
/// with short idle flickers between tool calls, sometimes a wait for
/// approval, and a long idle at the end of each turn.
fn timeline(r: std.Random, turns: usize, out: *std.ArrayList(Segment)) !void {
    const a = std.testing.allocator;
    try out.append(a, .{ .screen = test_screens.idle, .ms = 1_000 + r.uintLessThan(u64, 5_000) });
    for (0..turns) |_| {
        const bursts = 1 + r.uintLessThan(usize, 4);
        for (0..bursts) |i| {
            if (i > 0) {
                const pause = if (r.uintLessThan(u32, 4) == 0) test_screens.blocked else test_screens.idle;
                const ms = if (pause.ptr == test_screens.idle.ptr) 50 + r.uintLessThan(u64, 750) else 2_000 + r.uintLessThan(u64, 8_000);
                try out.append(a, .{ .screen = pause, .ms = ms });
            }
            try out.append(a, .{ .screen = test_screens.working, .ms = 3_000 + r.uintLessThan(u64, 17_000) });
        }
        try out.append(a, .{ .screen = test_screens.idle, .ms = 5_000 + r.uintLessThan(u64, 25_000) });
    }
}

/// Completions seen sampling `segments` every `period_ms`, give or take a
/// quarter, reading the screen whenever the monitor asks. With `set_back`,
/// the clock handed to the monitor is set back at random moments, by a few
/// milliseconds up to a day, while the session itself runs on.
fn completionsAt(segments: []const Segment, period_ms: u64, r: std.Random, set_back: bool) !u64 {
    var mon = Monitor.init(std.testing.allocator);
    defer mon.deinit();
    var at: u64 = r.uintLessThan(u64, period_ms);
    // Far enough from zero that a day's setbacks, many times over, stay
    // above it.
    var offset: u64 = 1 << 50;
    var start: u64 = 0;
    var activity: u64 = 0;
    for (segments) |segment| {
        while (at < start + segment.ms) : (at += period_ms - period_ms / 4 + r.uintLessThan(u64, period_ms / 2 + 1)) {
            const working = segment.screen.ptr == test_screens.working.ptr;
            if (working) activity += 1;
            if (set_back and r.uintLessThan(u32, 20) == 0) {
                const jumps = [_]u64{ 5, 50, 900, 60_000, 3_600_000, 86_400_000 };
                offset -= jumps[r.uintLessThan(usize, jumps.len)];
            }
            var o: Observation = .{ .at_ms = at + offset, .run = "r", .agent = "codex", .output = working, .activity = activity };
            if (mon.needsScreen("t", o)) o.screen = .{ .text = segment.screen };
            _ = try mon.observe("t", o);
        }
        start += segment.ms;
    }
    return mon.completion("t");
}

test "a session completes the same turns however often it is observed, and whatever its clock is set back by" {
    const seed = std.testing.random_seed;
    errdefer std.debug.print("agent state rate test failed; rerun with zig build test --seed 0x{x}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..50) |_| {
        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(std.testing.allocator);
        const turns = 1 + r.uintLessThan(usize, 5);
        try timeline(r, turns, &segments);
        for ([_]u64{ 16, 100, 500, 1_000, 2_000 }) |period| {
            try std.testing.expectEqual(@as(u64, turns), try completionsAt(segments.items, period, r, false));
            // A clock set back changes nothing: not a completion more, and
            // not one less.
            try std.testing.expectEqual(@as(u64, turns), try completionsAt(segments.items, period, r, true));
        }
    }
}
