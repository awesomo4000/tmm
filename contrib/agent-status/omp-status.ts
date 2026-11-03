// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Report what omp is doing as OSC 7501 records, so tmm shows it instead of
// guessing from the screen.
//
// omp has no command hooks. Its hooks are extensions: modules it loads into
// its own process, which subscribe to events with `pi.on`. So this is one,
// and it hands each record to tmm-report.sh beside it, the same emitter the
// Claude Code and Codex hooks use.
//
// The mapping, from omp 18.16 run in a tmux pane with every event logged,
// not from documentation:
//
//     agent_start                          working   a turn started
//     tool_execution_start                 working   with the tool name, rate limited
//     tool_approval_requested              blocked   kind=permission, with the tool
//     tool_execution_start, tool "ask"     blocked   kind=question
//     tool_approval_resolved,
//       tool_execution_end, tool "ask"     working   once nothing is waiting
//     agent_end                            done      finished, not yet looked at
//     agent_end, stopped "aborted"         idle      the person pressed Escape
//     agent_end, stopped "error"           error     with the message
//     auto_retry_start                     working   omp is trying the error again
//     auto_retry_end, success false        error     it gave up
//     session_switch                       clear     /new or a resumed session
//     session_shutdown                     clear     the record goes away
//
// Rules worth knowing:
//
//   - Only a session with a UI reports. A subagent runs a session of its own
//     without one in the same process, and its turns ending would mark the
//     pane done while the main turn is still working.
//   - A denied approval resolves the same way as an approved one, with
//     `approved: false`, and the turn goes on: the model is told and answers.
//     So both go back to working.
//   - Escape ends the turn with agent_end and nothing before it. The last
//     assistant message has `stopReason: "aborted"`, which is what tells it
//     from a turn that finished.
//   - An error turn ends with agent_end too, and omp decides to retry only
//     after that, in its own agent_end handler. So error comes first and
//     auto_retry_start corrects it, then the retry starts a fresh turn.
//   - Prompts are counted, not flagged. Parallel tool calls can each ask, and
//     answering one must not read as working while another is still up.
//
// Reports run one at a time, in order, and only the newest waiting one is
// sent: a record replaces the last, so a report that has been overtaken
// before it went out is not worth sending.
//
// Install it as a directory, `~/.omp/agent/extensions/tmm/index.ts` with
// tmm-report.sh beside it (install.sh omp), or load it for one run with
// `omp -e path/to/omp-status.ts`.

// @ts-nocheck

import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPORT = path.join(path.dirname(fileURLToPath(import.meta.url)), "tmm-report.sh");

// tool_execution_start fires on every tool call, and a batch of parallel reads
// can be dozens in a second. Only the tool name changes between them, so they
// are collapsed to at most one report in this window.
const TOOL_REPORT_INTERVAL_MS = 1000;

type Options = Record<string, string>;

let waiting: Options | undefined;
let sending: Promise<void> | undefined;

/** Queue a record; the promise settles once nothing is left to send. */
function report(options: Options): Promise<void> {
  waiting = options;
  sending ??= drain();
  return sending;
}

async function drain(): Promise<void> {
  while (waiting) {
    const next = waiting;
    waiting = undefined;
    await run(next);
  }
  // In the same step as the last check, so a record queued after it starts a
  // new drain rather than waiting on this finished one.
  sending = undefined;
}

function run(options: Options): Promise<void> {
  const args = Object.entries(options).map(([k, v]) => `${k}=${v}`);
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn("sh", [REPORT, ...args], { stdio: "ignore" });
    } catch {
      resolve();
      return;
    }
    // Never hold the next report back for long over one that hangs.
    const timer = setTimeout(() => {
      child.kill();
      resolve();
    }, 5000);
    timer.unref?.();
    child.on("error", () => {
      clearTimeout(timer);
      resolve();
    });
    child.on("close", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function lastAssistant(messages: unknown): any {
  if (!Array.isArray(messages)) return undefined;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (messages[i]?.role === "assistant") return messages[i];
  }
  return undefined;
}

export default function (pi) {
  // Nothing to report to outside tmux; tmm-report.sh would only exit.
  if (!process.env.TMUX || !process.env.TMUX_PANE) return;

  // `app` is on every report because a report replaces the whole record.
  const base = { app: "omp" };
  let state = "";
  let prompts = 0;
  let toolReported = 0;

  function set(next: string, extra: Options = {}): void {
    state = next;
    report({ ...base, state: next, ...extra });
  }

  function clear(): Promise<void> {
    state = "";
    prompts = 0;
    return report({ state: "clear" });
  }

  function ask(extra: Options): void {
    prompts += 1;
    set("blocked", extra);
  }

  function answered(): void {
    if (prompts === 0) return;
    prompts -= 1;
    if (prompts === 0 && state === "blocked") set("working");
  }

  pi.on("agent_start", (_event, ctx) => {
    if (!ctx?.hasUI) return;
    prompts = 0;
    set("working");
  });

  pi.on("tool_execution_start", (event, ctx) => {
    if (!ctx?.hasUI) return;
    const tool = typeof event?.toolName === "string" ? event.toolName : "";
    if (tool === "ask") {
      ask({ kind: "question" });
      return;
    }
    // Collapsed only while already working; out of any other state it is a
    // change that has to get through.
    const now = Date.now();
    if (state === "working" && now - toolReported < TOOL_REPORT_INTERVAL_MS) return;
    if (state === "blocked") return;
    toolReported = now;
    set("working", tool ? { title: tool } : {});
  });

  pi.on("tool_approval_requested", (event, ctx) => {
    if (!ctx?.hasUI) return;
    const tool = typeof event?.toolName === "string" ? event.toolName : "";
    ask(tool ? { kind: "permission", title: tool } : { kind: "permission" });
  });

  pi.on("tool_approval_resolved", (_event, ctx) => {
    if (!ctx?.hasUI) return;
    answered();
  });

  pi.on("tool_execution_end", (event, ctx) => {
    if (!ctx?.hasUI || event?.toolName !== "ask") return;
    answered();
  });

  pi.on("agent_end", (event, ctx) => {
    if (!ctx?.hasUI) return;
    prompts = 0;
    const last = lastAssistant(event?.messages);
    if (last?.stopReason === "aborted") {
      set("idle");
    } else if (last?.stopReason === "error") {
      const message = String(last.errorMessage ?? "");
      set("error", message ? { msg: message } : {});
    } else {
      set("done");
    }
  });

  pi.on("auto_retry_start", (_event, ctx) => {
    if (!ctx?.hasUI) return;
    set("working");
  });

  pi.on("auto_retry_end", (event, ctx) => {
    if (!ctx?.hasUI || event?.success !== false) return;
    const message = String(event.finalError ?? "");
    set("error", message ? { msg: message } : {});
  });

  pi.on("session_switch", (_event, ctx) => {
    if (!ctx?.hasUI) return;
    clear();
  });

  // Waited for: omp exits once its handlers return, and a clear still
  // running then would leave the record behind.
  pi.on("session_shutdown", (_event, ctx) => {
    if (!ctx?.hasUI) return;
    return clear();
  });
}
