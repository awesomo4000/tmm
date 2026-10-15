// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const tmux = @import("libtmux");
const m = @import("model.zig");
const status = @import("status.zig");
const cmstream = @import("cmstream.zig");
const control = @import("control.zig");
const istate = @import("state.zig");
const reconcile = @import("reconcile.zig");
const Allocator = std.mem.Allocator;
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    clients: []m.Client = &.{},
    sessions: []m.Session = &.{},
    panes: []m.Pane = &.{},
    context: []const u8 = "",
    cwd: []const u8 = "",
    focused_pane: []const u8 = "",
    failure: ?[]const u8 = null,
    valid: bool = false,
    rename_result: ?struct { id: []const u8, success: bool } = null,
    pub fn destroy(self: *Snapshot, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};
pub const Request = struct {
    client: m.Client,
    session: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    window: ?[]const u8 = null,
    completion: u64 = 0,
    run_identity: ?[]const u8 = null,
    pub fn copy(alloc: Allocator, client: m.Client, session: ?[]const u8) !Request {
        const name = try alloc.dupe(u8, client.name);
        errdefer alloc.free(name);
        const pid = try alloc.dupe(u8, client.pid);
        errdefer alloc.free(pid);
        const created = try alloc.dupe(u8, client.created);
        errdefer alloc.free(created);
        return .{ .client = .{ .name = name, .pid = pid, .created = created, .session = "" }, .session = if (session) |value| try alloc.dupe(u8, value) else null };
    }
    pub fn deinit(self: Request, alloc: Allocator) void {
        alloc.free(self.client.name);
        alloc.free(self.client.pid);
        alloc.free(self.client.created);
        if (self.session) |s| alloc.free(s);
        if (self.pane) |p| alloc.free(p);
        if (self.window) |w| alloc.free(w);
        if (self.run_identity) |id| alloc.free(id);
    }
};
pub const Rename = struct {
    create: bool = false,
    display: ?Request = null,
    id: []const u8,
    name: []const u8,
    pub fn deinit(self: Rename, a: Allocator) void {
        a.free(self.id);
        a.free(self.name);
        if (self.display) |d| d.deinit(a);
    }
};
pub const Shared = struct {
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    /// Notification lines handed to the collector, as owned copies: event
    /// payloads borrow from the stream's read buffer and would dangle.
    events: std.ArrayList([]u8) = .empty,
    /// Pane ids that emitted output, forwarded as ids rather than whole
    /// `%output` lines: the payload can be large and only the id is needed to
    /// decide whether that pane's agent status must be re-captured.
    output_panes: std.ArrayList([]u8) = .empty,

    /// Set when a line could not be queued. Losing an event means the
    /// incremental model cannot be trusted, so the collector escalates to a
    /// full query rather than carrying on with a gap.
    events_dropped: bool = false,

    /// Posted by controlWorker when tmux state changed; the collector waits on
    /// it instead of polling. Statically initializable, no deinit. The wait is
    /// cancellable, so task.cancel unblocks a collector parked here even if the
    /// control stream is wedged.
    wake: std.Io.Semaphore = .{},
    request: ?Request = null,
    blink: ?Request = null,
    rename: ?Rename = null,
    pub fn renameSession(self: *Shared, io: std.Io, a: Allocator, id: []const u8, name: []const u8, create: bool, display: ?m.Client) !void {
        const owned_id = try a.dupe(u8, id);
        errdefer a.free(owned_id);
        const owned_name = try a.dupe(u8, name);
        errdefer a.free(owned_name);
        const owned_display = if (display) |d| try Request.copy(a, d, null) else null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.rename) |old| old.deinit(a);
        self.rename = .{ .id = owned_id, .name = owned_name, .create = create, .display = owned_display };
        self.wake.post(io);
    }
    pub fn blinkDisplay(self: *Shared, io: std.Io, alloc: Allocator, client: m.Client) !void {
        const request = try Request.copy(alloc, client, null);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.blink) |old| old.deinit(alloc);
        self.blink = request;
        self.wake.post(io);
    }
    /// Queue one notification line for the collector. Never blocks on capacity:
    /// on overflow it records the loss instead, which forces a resync.
    pub fn pushEvent(self: *Shared, io: std.Io, alloc: Allocator, line: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.events.items.len >= max_queued_events) {
            self.events_dropped = true;
            return;
        }
        const copy = alloc.dupe(u8, line) catch {
            self.events_dropped = true;
            return;
        };
        self.events.append(alloc, copy) catch {
            alloc.free(copy);
            self.events_dropped = true;
        };
    }

    /// Hand the queued lines to the caller, who owns them. `dropped` reports
    /// whether anything was lost since the last drain.
    pub fn takeEvents(self: *Shared, io: std.Io, alloc: Allocator, dropped: *bool) []const []u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        dropped.* = self.events_dropped;
        self.events_dropped = false;
        return self.events.toOwnedSlice(alloc) catch blk: {
            // Could not hand them over; drop them and force a resync rather
            // than leaving the collector to apply a partial batch.
            for (self.events.items) |l| alloc.free(l);
            self.events.clearRetainingCapacity();
            dropped.* = true;
            break :blk &.{};
        };
    }

    /// Note that a pane emitted output. Deduplicated and capped; dropping one
    /// only costs a skipped capture, which the sample budget then covers.
    pub fn pushOutputPane(self: *Shared, io: std.Io, alloc: Allocator, pane: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.output_panes.items) |p| if (std.mem.eql(u8, p, pane)) return;
        if (self.output_panes.items.len >= 256) return;
        const copy = alloc.dupe(u8, pane) catch return;
        self.output_panes.append(alloc, copy) catch alloc.free(copy);
    }

    pub fn takeOutputPanes(self: *Shared, io: std.Io, alloc: Allocator) []const []u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.output_panes.toOwnedSlice(alloc) catch blk: {
            for (self.output_panes.items) |p| alloc.free(p);
            self.output_panes.clearRetainingCapacity();
            break :blk &.{};
        };
    }

    pub fn send(self: *Shared, io: std.Io, alloc: Allocator, request: Request) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.request) |old| old.deinit(alloc);
        self.request = request;
        self.wake.post(io);
    }
};
pub const Connection = struct {
    server: tmux.Server,
    diagnostic: ?[]const u8 = null,
    /// Queries issued on this connection, for TMM_QUERY_LOG measurement.
    query_count: usize = 0,
    /// Optional control-mode client used for read-only queries, so they cost a
    /// write and a read on an existing connection rather than a fork and exec
    /// of tmux. Null falls back to the subprocess path.
    queries: ?*cmstream.Stream = null,
    pub fn init(a: Allocator, io: std.Io, environ: std.process.Environ, opts: tmux.ServerOptions) !Connection {
        return .{ .server = try tmux.Server.init(a, io, environ, opts) };
    }
    pub fn deinit(self: *Connection) void {
        self.server.deinit();
    }
};
/// Read-only query. Prefers the control client; falls back to a subprocess if
/// there is none, or if an argument cannot be quoted for the command parser.
///
/// Only use this for commands whose arguments are fixed by the program (format
/// strings, tmux ids). Anything carrying user data, and anything that mutates
/// state, goes through `query` so the arguments are passed as a real argv with
/// no command-line parsing in between.
fn queryRead(connection: *Connection, args: []const []const u8) ![]u8 {
    connection.query_count += 1;
    const stream = connection.queries orelse return query(connection, args);
    const alloc = connection.server.allocator;
    const reply = stream.requestArgv(alloc, args) catch |err| switch (err) {
        // Unquotable argument, or the stream died. Either way the subprocess
        // path still works, so fall back rather than failing the collect.
        error.UnquotableArgument, error.StreamEnded => return query(connection, args),
        else => return err,
    };
    defer reply.deinit(alloc);
    if (!reply.ok) {
        connection.diagnostic = if (reply.lines.len > 0)
            alloc.dupe(u8, reply.lines[0]) catch null
        else
            null;
        return error.TmuxCommandFailed;
    }
    return reply.join(alloc);
}

fn query(connection: *Connection, args: []const []const u8) ![]u8 {
    connection.query_count += 1;
    var result = try connection.server.exec(args);
    if (!result.success()) {
        defer result.deinit();
        connection.diagnostic = try std.fmt.allocPrint(connection.server.allocator, "{s}: {s}", .{
            args[0], std.mem.trim(u8, result.stderr, "\r\n"),
        });
        return error.TmuxCommandFailed;
    }
    connection.server.allocator.free(result.stderr);
    return result.stdout;
}
/// Attached displays and, for each, where it currently is.
///
/// The position fields have to come from here. `display-message -c <client>`
/// looks like the way to ask where one client is, but `-c` only selects the
/// client for client-specific formats: the target the formats expand against
/// is the server's current pane, so every client gets the same answer and it
/// does not move when a client navigates. `list-clients -F` expands per client
/// and does follow navigation.
pub fn clients(server: *Connection, alloc: Allocator) ![]m.Client {
    const data = try queryRead(server, &.{ "list-clients", "-F", m.format(&.{ "client_name", "client_pid", "client_created", "session_id", "client_control_mode", "window_id", "pane_id", "pane_current_path" }) });
    const rows = try m.records(8, alloc, data);
    var result: std.ArrayList(m.Client) = .empty;
    for (rows) |r| if (std.mem.eql(u8, r[4], "0")) {
        try result.append(alloc, .{ .name = r[0], .pid = r[1], .created = r[2], .session = r[3], .window = r[5], .pane = r[6], .cwd = r[7] });
    };
    return result.toOwnedSlice(alloc);
}
pub fn collect(server: *Connection, snapshot: *Snapshot, target: ?Request) !void {
    return collectWithCache(server, snapshot, target, null, null);
}

/// As `collect`, but reusing cached agent verdicts for panes that emitted no
/// output, which is where most of a pass's queries go.
pub fn collectWithCache(server: *Connection, snapshot: *Snapshot, target: ?Request, agents: ?*AgentCache, model: ?*istate.State) !void {
    const a = snapshot.arena.allocator();
    snapshot.clients = try clients(server, a);
    if (target) |t| {
        var found = false;
        for (snapshot.clients) |c| if (c.same(t.client)) {
            found = true;
            break;
        };
        if (!found) {
            snapshot.failure = "Target disconnected. Select a display explicitly.";
        } else {
            if (t.pane) |pane| {
                const data = try queryRead(server, &.{ "list-panes", "-s", "-t", t.session.?, "-F", m.format(&.{ "pane_id", "window_id" }) });
                const pane_rows = try m.records(2, a, data);
                var exists = false;
                for (pane_rows) |r| if (std.mem.eql(u8, r[0], pane) and std.mem.eql(u8, r[1], t.window.?)) {
                    exists = true;
                    break;
                };
                if (!exists) return error.AgentPaneDisappeared;
            }
            if (t.session) |s| _ = try query(server, &.{ "switch-client", "-c", t.client.name, "-t", s });
            if (t.pane) |pane| {
                const window_target = try std.fmt.allocPrint(a, "{s}:{s}", .{ t.session.?, t.window.? });
                _ = try query(server, &.{ "select-window", "-t", window_target });
                _ = try query(server, &.{ "select-pane", "-t", pane });
            }
            // Re-read the client list when this pass moved the display, so
            // the snapshot describes where it ended up rather than where it
            // was before. Without a navigation the list read above is current.
            if (t.session != null or t.pane != null) snapshot.clients = try clients(server, a);
            var located = false;
            for (snapshot.clients) |c| if (c.same(t.client)) {
                snapshot.context = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ c.session, c.window, c.pane });
                snapshot.cwd = c.cwd;
                snapshot.focused_pane = c.pane;
                located = true;
                break;
            };
            if (!located) return error.MalformedContext;
        }
    }
    const session_data = try queryRead(server, &.{ "list-sessions", "-F", m.format(&.{ "session_id", "session_name", "session_path" }) });
    const session_rows = try m.records(3, a, session_data);
    snapshot.sessions = try a.alloc(m.Session, session_rows.len);
    for (session_rows, snapshot.sessions) |r, *s| s.* = .{ .id = r[0], .name = r[1], .path = r[2] };
    const pane_data = try queryRead(server, &.{ "list-panes", "-a", "-F", m.format(&.{ "session_id", "window_id", "pane_id", "pane_current_path", "pane_current_command", "@agent_hint", "@agent_state", "@agent_status_text", "pane_pid", "@agent_session_id", "window_activity" }) });
    const pane_rows = try m.records(11, a, pane_data);
    snapshot.panes = try a.alloc(m.Pane, pane_rows.len);
    for (pane_rows, snapshot.panes) |r, *p| p.* = .{ .session = r[0], .window = r[1], .id = r[2], .cwd = r[3], .command = r[4], .agent = r[5], .state = r[6], .status = r[7], .activity = r[10] };
    // One process table per refresh, never a shell command or pane-output scrape.
    const process_result = std.process.run(a, server.server.io, .{
        .argv = &.{ "ps", "-axo", "pid=,ppid=,comm=" },
        .stdout_limit = .limited(10 * 1024 * 1024),
    }) catch null;
    var processes: []const m.Process = &.{};
    if (process_result) |result| {
        if (result.term == .exited and result.term.exited == 0)
            processes = try m.parseProcesses(a, result.stdout);
    }
    for (snapshot.clients) |*client| {
        const pid = std.fmt.parseInt(u32, client.pid, 10) catch continue;
        client.terminal = m.terminalOwner(processes, pid);
    }
    for (snapshot.panes, pane_rows) |*pane, record| {
        const root_pid = std.fmt.parseInt(u32, record[8], 10) catch 0;
        const process = m.processAgentInfo(processes, root_pid);
        pane.run_identity = try std.fmt.allocPrint(a, "{s}:{d}:{s}", .{ record[8], if (process) |info| info.pid else root_pid, record[9] });
        if (pane.agent.len > 0) {
            pane.agent_source = "metadata";
        } else {
            const pid = std.fmt.parseInt(u32, record[8], 10) catch 0;
            if (m.processAgent(processes, pid) orelse m.agentCommand(pane.command)) |agent| {
                pane.agent = agent;
                pane.agent_source = "process";
                // Presence alone says nothing about turn completion.
                pane.state = "";
                pane.status = "";
            }
        }
    }
    var detections: std.StringHashMap(status.Verdict) = .init(a);
    for (snapshot.panes) |*pane| {
        if (pane.agent.len == 0) continue;
        if (pane.state.len > 0) {
            pane.status_source = "metadata";
            pane.status_rule = "explicit-pane-state";
            continue;
        }
        if (!std.mem.eql(u8, pane.agent, "codex") and !std.mem.eql(u8, pane.agent, "claude")) continue;
        // Reuse a cached verdict when this pane emitted nothing and has
        // settled: capture plus title is two queries and dominates a pass.
        if (agents) |cache| {
            const had_output = if (model) |mo| mo.hadOutput(pane.id) else true;
            if (!cache.needsCapture(pane.id, had_output, pane.activity)) {
                if (cache.cached(pane.id)) |v| {
                    pane.state = @tagName(v.state);
                    pane.status_source = "screen";
                    pane.status_rule = v.rule;
                    pane.interrupted = v.interrupted;
                    continue;
                }
            }
        }
        const verdict = detections.get(pane.id) orelse blk: {
            // Capture live screen, not copy-mode scroll position. No screen data is retained.
            const screen = queryRead(server, &.{ "capture-pane", "-p", "-t", pane.id, "-S", "0" }) catch
                break :blk status.Verdict{ .state = .unknown, .rule = "capture-failed" };
            const title_data = queryRead(server, &.{ "display-message", "-p", "-t", pane.id, "#{pane_title}" }) catch "";
            const result = status.classify(pane.agent, screen, std.mem.trim(u8, title_data, "\r\n"));
            try detections.put(pane.id, result);
            if (agents) |cache| cache.record(pane.id, result, pane.activity);
            break :blk result;
        };
        pane.state = @tagName(verdict.state);
        pane.status_source = "screen";
        pane.status_rule = verdict.rule;
        pane.interrupted = verdict.interrupted;
    }
    snapshot.valid = true;
}
pub fn worker(io: std.Io, alloc: Allocator, environ: std.process.Environ, opts: tmux.ServerOptions, shared: *Shared, loop: anytype) void {
    var tracker = Tracker.init(alloc);
    defer tracker.deinit();
    var target: ?Request = null;
    defer if (target) |t| t.deinit(alloc);
    // Long-lived control client for read-only queries. Opened once: a client
    // per iteration would cost as much as the fork and exec it replaces. Its
    // own notifications are dropped, because controlWorker handles events.
    const query_stream: ?*cmstream.Stream = cmstream.Stream.open(alloc, io, .{
        .socket = opts.socket_path,
        .label = opts.socket_name,
        .session = null,
        .tmux_bin = opts.tmux_bin orelse "tmux",
    }) catch null;
    if (query_stream) |qs| qs.discard_notifications = true;
    defer if (query_stream) |qs| qs.close();

    // Incremental model, maintained across iterations from the event queue and
    // checked against each full query. It is not yet the source of the snapshot
    // the UI renders: the full collect stays authoritative while the apply
    // logic is being proven. Divergence is reported through TMM_RECONCILE_LOG.
    var model = istate.State.init(alloc);
    defer model.deinit();
    var agents = AgentCache.init(alloc);
    defer agents.deinit();
    const reconcile_log = environ.getAlloc(alloc, "TMM_RECONCILE_LOG") catch null;
    defer if (reconcile_log) |path| alloc.free(path);
    const query_log = environ.getAlloc(alloc, "TMM_QUERY_LOG") catch null;
    defer if (query_log) |path| alloc.free(path);
    while (!shared.stopping.load(.acquire)) {
        shared.mutex.lockUncancelable(io);
        if (shared.request) |r| {
            if (target) |t| t.deinit(alloc);
            target = r;
            shared.request = null;
        }
        const rename = shared.rename;
        shared.rename = null;
        const blink = shared.blink;
        shared.blink = null;
        shared.mutex.unlock(io);
        defer if (blink) |request| request.deinit(alloc);
        defer if (rename) |r| r.deinit(alloc);
        // Apply whatever the control stream reported since the last pass.
        var dropped = false;
        const lines = shared.takeEvents(io, alloc, &dropped);
        if (dropped) model.needs_full = true;
        for (lines) |line| {
            var parser: control.Parser = .{};
            // Only notifications are queued, and those never open a guard
            // block, so a fresh parser per line cannot desynchronise.
            _ = model.apply(parser.feed(line)) catch {
                model.needs_full = true;
            };
            alloc.free(line);
        }
        if (lines.len > 0) alloc.free(lines);

        const emitted = shared.takeOutputPanes(io, alloc);
        for (emitted) |pane| {
            model.noteOutput(pane) catch {};
            alloc.free(pane);
        }
        if (emitted.len > 0) alloc.free(emitted);

        const s = alloc.create(Snapshot) catch return;
        s.* = .{ .arena = .init(alloc) };
        var server = Connection.init(s.arena.allocator(), io, environ, opts) catch |err| {
            // No connection yet, so there is no diagnostic to prefer.
            s.failure = lostServer(err) orelse @errorName(err);
            loop.postEvent(.{ .snapshot = s }) catch {
                s.destroy(alloc);
                return;
            };
            return;
        };
        server.queries = query_stream;
        var rename_failure: ?[]const u8 = null;
        if (rename) |r| {
            const id = s.arena.allocator().dupe(u8, r.id) catch {
                s.destroy(alloc);
                return;
            };
            s.rename_result = .{ .id = id, .success = false };
            if (r.create) {
                createSession(&server, r, &s.rename_result.?.success) catch |err| {
                    const why = reason(&server, err);
                    rename_failure = if (s.rename_result.?.success)
                        std.fmt.allocPrint(s.arena.allocator(), "Session {s} created; display switch failed: {s}", .{ r.name, why }) catch "Session created; display switch failed"
                    else
                        why;
                };
            } else {
                if (query(&server, &.{ "rename-session", "-t", r.id, "--", r.name })) |_| {
                    s.rename_result.?.success = true;
                } else |err| rename_failure = reason(&server, err);
            }
        }
        // A creation already navigated the display. Do not replay an older
        // queued navigation while reading the resulting topology.
        var collect_target = target;
        if (rename) |r| if (r.create and s.rename_result.?.success) {
            if (target) |t| collect_target = .{ .client = t.client };
        };
        collectWithCache(&server, s, collect_target, &agents, &model) catch |err| {
            s.failure = reason(&server, err);
        };
        if (rename_failure) |failure| s.failure = failure;
        if (blink) |request| {
            flashDisplay(&server, request.client) catch |err| {
                s.failure = reason(&server, err);
            };
        }
        if (s.valid) tracker.update(s, target) catch {
            s.failure = "Completion tracking failed";
        };
        server.deinit();
        if (target) |*t| if (t.session) |session| {
            alloc.free(session);
            t.session = null;
            if (t.pane) |p| alloc.free(p);
            if (t.window) |w| alloc.free(w);
            t.pane = null;
            t.window = null;
            if (t.run_identity) |id| alloc.free(id);
            t.run_identity = null;
        };
        // Check the incremental model against the authoritative query, then
        // adopt it. Skipped when the model already knows it is stale, since
        // reporting the gap it has already declared would be noise.
        if (query_log) |path| appendCount(io, alloc, path, server.query_count);
        if (s.valid) {
            // This pass's capture decisions have consumed the output marks.
            agents.prune(s.panes);
            model.clearOutput();
            if (!model.isDirty()) checkModel(io, alloc, &model, s, reconcile_log);
            model.adopt(s.sessions, s.panes) catch {
                model.needs_full = true;
            };
        }

        if (shared.stopping.load(.acquire)) {
            s.destroy(alloc);
            return;
        }
        loop.postEvent(.{ .snapshot = s }) catch {
            s.destroy(alloc);
            return;
        };
        // Event-driven steady state: controlWorker posts on tmux changes. If the
        // control stream cannot run it posts on a 500 ms cadence instead, so
        // the degraded path matches the old fixed poll exactly.
        shared.wake.wait(io) catch return;
    }
}

/// Report structural divergence between the incremental model and a full query.
/// Writes to the path in TMM_RECONCILE_LOG when set, so the integration suite
/// can assert nothing diverged; a normal run pays nothing. The file is
/// truncated each time, so it holds the most recent divergence rather than a
/// history, which is all that is needed to tell whether any occurred.
fn checkModel(
    io: std.Io,
    alloc: Allocator,
    model: *istate.State,
    s: *Snapshot,
    log_path: ?[]const u8,
) void {
    const path = log_path orelse return;
    const mismatches = reconcile.diff(alloc, .{
        .sessions = model.sessions.items,
        .panes = model.panes.items,
    }, .{
        .sessions = s.sessions,
        .panes = s.panes,
    }) catch return;
    defer alloc.free(mismatches);
    if (mismatches.len == 0) return;

    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    for (mismatches) |mismatch| {
        const line = reconcile.describe(alloc, mismatch) catch continue;
        defer alloc.free(line);
        w.interface.writeAll(line) catch {};
        w.interface.writeAll("\n") catch {};
    }
    w.interface.flush() catch {};
}

/// Captures still owed to a pane after its last output. The completion rule
/// needs two consecutive idle samples, so a pane must keep being sampled for a
/// few passes after it stops emitting, or a working-to-idle transition would
/// never be observed and completions would be lost. Three covers working, then
/// idle, then idle.
const samples_after_output: u8 = 3;

/// Agent verdicts kept across passes, so a pane that emitted nothing need not
/// be re-captured. Capture plus title is two tmux queries per agent pane per
/// pass, measured as two thirds of the cost of a pass with three agents.
pub const AgentCache = struct {
    alloc: Allocator,
    entries: std.StringHashMap(Entry),

    pub const Entry = struct {
        verdict: status.Verdict,
        /// Remaining captures owed; zero means the pane has settled.
        budget: u8,
        /// `window_activity` when this verdict was taken, or null when tmux
        /// did not report one. A change means the window produced output.
        activity: ?u64,
    };

    pub fn init(alloc: Allocator) AgentCache {
        return .{ .alloc = alloc, .entries = .init(alloc) };
    }

    pub fn deinit(self: *AgentCache) void {
        var it = self.entries.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.entries.deinit();
    }

    /// Whether this pane must be captured this pass.
    ///
    /// `had_output` comes from `%output` on the control stream, which is exact
    /// and per pane but only arrives for the session our control client is
    /// attached to. A pane in any other session would otherwise never be
    /// captured again once its budget ran out, freezing its status for the
    /// rest of the run. `window_activity` is reported for every window
    /// whatever any client is looking at, so it covers the rest. It is a
    /// one-second stamp for the whole window, which only makes this capture
    /// more often than strictly needed.
    pub fn needsCapture(self: *AgentCache, pane: []const u8, had_output: bool, activity: []const u8) bool {
        const stamp = parseActivity(activity);
        const existing = self.entries.getPtr(pane) orelse return true;
        if (had_output or existing.activity == null or stamp == null or
            existing.activity.? != stamp.?)
        {
            existing.budget = samples_after_output;
            return true;
        }
        return existing.budget > 0;
    }

    pub fn record(self: *AgentCache, pane: []const u8, verdict: status.Verdict, activity: []const u8) void {
        const stamp = parseActivity(activity);
        if (self.entries.getPtr(pane)) |e| {
            e.verdict = verdict;
            e.activity = stamp;
            if (e.budget > 0) e.budget -= 1;
            return;
        }
        const key = self.alloc.dupe(u8, pane) catch return;
        self.entries.put(key, .{
            .verdict = verdict,
            .budget = samples_after_output - 1,
            .activity = stamp,
        }) catch self.alloc.free(key);
    }

    /// tmux reports `window_activity` as a unix time, and as an empty string
    /// for a window that has produced nothing yet. Null means unknown, which
    /// callers treat as a reason to capture rather than a reason to skip.
    fn parseActivity(activity: []const u8) ?u64 {
        if (activity.len == 0) return null;
        return std.fmt.parseInt(u64, activity, 10) catch null;
    }

    pub fn cached(self: *AgentCache, pane: []const u8) ?status.Verdict {
        const e = self.entries.getPtr(pane) orelse return null;
        return e.verdict;
    }

    /// Forget panes that no longer exist, so the cache cannot grow without end.
    pub fn prune(self: *AgentCache, panes: []const m.Pane) void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.alloc);
        var it = self.entries.iterator();
        outer: while (it.next()) |e| {
            for (panes) |pane| if (std.mem.eql(u8, pane.id, e.key_ptr.*)) continue :outer;
            stale.append(self.alloc, e.key_ptr.*) catch return;
        }
        for (stale.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| self.alloc.free(kv.key);
        }
    }
};

/// A human reason for a failed query, preferring whatever tmux said.
///
/// Without this a lost server reports whichever error surfaced first, and
/// which one that is, is a race: tmux usually gets to print "no server
/// running" before the socket is noticed to be gone, but when the write fails
/// first there is no diagnostic to read and the sidebar showed the bare Zig
/// error name instead.
fn reason(server: *Connection, err: anyerror) []const u8 {
    if (server.diagnostic) |d| return d;
    return lostServer(err) orelse @errorName(err);
}

/// The message for an error that only means the socket is gone, or null when
/// the error says something more specific.
fn lostServer(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        => "Server connection lost",
        else => null,
    };
}

/// Append one collect's query count, for measuring the effect of changes to
/// how much each pass asks tmux. Gated on TMM_QUERY_LOG; free when unset.
fn appendCount(io: std.Io, alloc: Allocator, path: []const u8, count: usize) void {
    const line = std.fmt.allocPrint(alloc, "{d}\n", .{count}) catch return;
    defer alloc.free(line);
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
    defer file.close(io);
    const st = file.stat(io) catch return;
    const end = st.size;
    _ = file.writePositionalAll(io, line, end) catch {};
}

/// Cap on queued notification lines. Overflow forces a full resync, which is
/// correct but expensive, so this is generous relative to any realistic burst.
const max_queued_events: usize = 1024;

/// How often %output alone may wake the collector. Structural events wake it
/// immediately; pane output is throttled because it arrives per keystroke, and
/// the only thing that needs it is agent-status screen inspection, which used
/// to run on the 500 ms poll anyway.
const output_wake_interval_ms: i64 = 500;

/// Floor sampling rate. Control events make the UI react immediately, but some
/// state is not derivable from events yet: agent completion needs two
/// consecutive idle samples, and an idle agent emits no %output to trigger the
/// second one. Until status.zig derives agent state from live %output (Phase 2
/// of the compositor plan), the collector still needs a periodic tick. This
/// restores exactly the old cadence as a floor; event wakes sit on top of it.
pub fn heartbeatWorker(io: std.Io, shared: *Shared) void {
    while (!shared.stopping.load(.acquire)) {
        io.sleep(.fromMilliseconds(500), .awake) catch return;
        shared.wake.post(io);
    }
}

/// Reads the control-mode stream and wakes the collector when tmux state
/// changes. Runs as its own task so a stalled stream cannot delay shutdown:
/// the collector parks on a cancellable semaphore wait, not on this loop.
pub fn controlWorker(io: std.Io, alloc: Allocator, opts: tmux.ServerOptions, shared: *Shared) void {
    while (!shared.stopping.load(.acquire)) {
        const stream = cmstream.Stream.open(alloc, io, .{
            .socket = opts.socket_path,
            .label = opts.socket_name,
            .session = null,
            .tmux_bin = opts.tmux_bin orelse "tmux",
        }) catch {
            // No control stream: fall back to the historical fixed cadence so
            // the UI keeps refreshing rather than freezing.
            shared.wake.post(io);
            io.sleep(.fromMilliseconds(500), .awake) catch return;
            continue;
        };
        defer stream.close();

        var last_output_wake: i64 = 0;
        while (!shared.stopping.load(.acquire)) {
            const ev = (stream.next() catch break) orelse break;
            switch (ev) {
                // Pane bytes: throttle, or a busy pane wakes the collector on
                // every keystroke and we are back to worse than polling.
                .output, .extended_output => {
                    // std.time.milliTimestamp is gone in 0.16; .awake is the
                    // monotonic clock this codebase already sleeps against.
                    // Always forward which pane moved: that is what decides
                    // whether its agent status needs re-capturing. Only the
                    // wake is throttled.
                    switch (ev) {
                        .output => |o| shared.pushOutputPane(io, alloc, o.pane),
                        .extended_output => |o| shared.pushOutputPane(io, alloc, o.pane),
                        else => {},
                    }
                    const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
                    if (now - last_output_wake >= output_wake_interval_ms) {
                        last_output_wake = now;
                        shared.wake.post(io);
                    }
                },
                // Guard-block bookkeeping for our own commands changes nothing.
                .reply_begin, .reply_line, .reply_end, .unknown => {},
                // Everything else is structural. Hand the raw line to the
                // collector so it can update the incremental model, then wake
                // it. Payloads borrow from the read buffer, hence the line.
                else => {
                    shared.pushEvent(io, alloc, stream.lastLine());
                    shared.wake.post(io);
                },
            }
            if (ev == .exit) break;
        }
        // Stream ended (server died, or we were detached). Wake once so the
        // collector observes the failure, then retry unless we are stopping.
        shared.wake.post(io);
        if (shared.stopping.load(.acquire)) return;
        io.sleep(.fromMilliseconds(500), .awake) catch return;
    }
}

/// Confirm the display is still attached, and report where it is. The caller
/// needs both, and taking them from one read means the check and the position
/// cannot disagree.
fn attachedClient(server: *Connection, expected: m.Client) !m.Client {
    for (try clients(server, server.server.allocator)) |client| if (client.same(expected)) return client;
    return error.SelectedDisplayDisconnected;
}
fn createSession(server: *Connection, edit: Rename, created: *bool) !void {
    const display = edit.display orelse return error.SelectDisplayFirst;
    // The new session starts in the directory of the pane the display is on.
    // That path comes from the client listing for the same reason the marker
    // does: `display-message -c` reports the server's current pane, not this
    // client's. See `clients`.
    const current = try attachedClient(server, display.client);
    if (current.cwd.len == 0) return error.MissingPaneDirectory;
    const output = try query(server, &.{ "new-session", "-d", "-P", "-F", "#{session_id}", "-s", edit.name, "-n", edit.name, "-c", current.cwd });
    // Creation is committed even if the display disconnects before switching.
    // Close the editor on that partial success so retry cannot duplicate it.
    created.* = true;
    const id = std.mem.trim(u8, output, "\r\n");
    _ = try attachedClient(server, display.client);
    _ = try query(server, &.{ "switch-client", "-c", display.client.name, "-t", id });
}

/// Briefly mark only this client; never change shared session styling or focus.
fn flashDisplay(server: *Connection, client: m.Client) !void {
    const a = server.server.allocator;
    const message = try std.fmt.allocPrint(a, ">>> tmm display: {s} <<<", .{client.name});
    const current = try clients(server, a);
    var found = false;
    for (current) |c| if (c.same(client)) {
        found = true;
        break;
    };
    if (!found) return error.DisplayDisconnected;
    _ = query(server, &.{ "display-message", "-c", client.name, "-d", "5000", "-N", "-C", "-l", message }) catch |err| {
        // tmux 3.4 lacks centered messages. Keep the same client and duration
        // using its status-line message when option parsing rejects -C.
        const diagnostic = server.diagnostic orelse return err;
        if (std.mem.indexOf(u8, diagnostic, "command display-message: unknown flag -C") == null) return err;
        server.diagnostic = null;
        _ = try query(server, &.{ "display-message", "-c", client.name, "-d", "5000", "-N", "-l", message });
        return;
    };
}

const Tracker = struct {
    a: Allocator,
    tracks: std.StringHashMap(status.Track),
    fn init(a: Allocator) Tracker {
        return .{ .a = a, .tracks = .init(a) };
    }
    fn deinit(self: *Tracker) void {
        var keys = self.tracks.keyIterator();
        while (keys.next()) |key| self.a.free(key.*);
        self.tracks.deinit();
    }
    fn update(self: *Tracker, snapshot: *Snapshot, request: ?Request) !void {
        var values = self.tracks.valueIterator();
        while (values.next()) |value| value.visited = false;
        const a = snapshot.arena.allocator();
        for (snapshot.panes) |*pane| {
            if (pane.agent.len == 0) continue;
            const key = try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ pane.id, pane.run_identity, pane.agent });
            const entry = try self.tracks.getOrPut(key);
            if (!entry.found_existing) {
                entry.key_ptr.* = self.a.dupe(u8, key) catch |err| {
                    _ = self.tracks.remove(key);
                    return err;
                };
                entry.value_ptr.* = .{};
            }
            const track = entry.value_ptr;
            if (!track.visited) track.observe(.{ .state = status.metadata(pane.state), .rule = pane.status_rule, .interrupted = pane.interrupted }, if (std.mem.eql(u8, pane.status_source, "metadata")) pane.state else null);
            // Acknowledge exactly the receipt the clicked row displayed, and only
            // after successful navigation. Never mark a newly finished turn seen.
            if (snapshot.failure == null) if (request) |r| if (r.pane) |id| {
                if (std.mem.eql(u8, id, pane.id) and std.mem.eql(u8, snapshot.focused_pane, pane.id))
                    if (r.run_identity) |identity| {
                        if (std.mem.eql(u8, identity, pane.run_identity)) track.acknowledge(r.completion);
                    };
            };
            pane.completion = track.generation;
            pane.unread = track.unread();
            const state = status.metadata(pane.state);
            if (state == .idle or state == .done) pane.state = if (pane.unread) "done" else "idle";
        }
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.a);
        var entries = self.tracks.iterator();
        while (entries.next()) |entry| if (!entry.value_ptr.visited) try stale.append(self.a, entry.key_ptr.*);
        for (stale.items) |key| {
            _ = self.tracks.remove(key);
            self.a.free(key);
        }
    }
};
