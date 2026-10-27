# Changelog

## 10/27/2026

- Started the session bar at the first pane, leaving the session's name clear; a folded session has none.
- Drew the half circle as the Powerline rounded cap, U+E0B4, which meets the bar and fills the row's height.
- Drew the session bar unbroken down the whole group, with a half circle growing out of it at the current pane, and at the pane under the pointer, in place of the `▸`.
- Gathered every direct colour into `src/palette.zig`, named by look and then by job; the drawing code asks only for the job.
- Put the selected session on a dark blue-teal card the height of its bar, fading toward the background along a cubic curve that drops late, to within a step or two of it at the right edge, and dimmed the hover bar well below the selection's, so the two are easy to tell apart.
- Marked sessions with a bar in a one-column gutter on the left, through the blank row that closes each, with a half circle at the pane's row: bright green-cyan for the selection, the same dimmed and greyed for the pointer or cursor. Lines are no longer recoloured.
- Dropped the coloured background behind the selection, which made its text hard to read. Server and display names are now green, apart from the pink headings, indented like panes with a `➤` beside the selected one and a dim one beside the pointer's.
- Replaced the `blink` row with a `✶` at the end of the selected display.
- Renamed the message for a selected display that went away from "Target disconnected" to "Display disconnected".
- Cleared the hover when the sidebar loses focus. Leaving the pane without a click still leaves it lit: nothing tells a pane the pointer has gone.
- Selected the display when it is the only one attached and none has been chosen, at launch or when the first one attaches.
- Picked the banner lettering at random on each launch, leaving out the one-line fallback. `TMM_BANNER` still asks for one by name.
- Set the subtitle to the right of the banner as `tmux` over `µmanager`, the `t` above the `µ`, centred on the banner's height. The one-line title reads `tmm : tmux µmanager`.
- Cut the test suite from about 130 s to about 15 s. The end-to-end tests now run side by side through `tests/run.py`, and `integration.py` and `follow.py` wait for the condition they check instead of sleeping a fixed time after every step: 66 s to 15 s, and 19 s to 10 s. Converting them exposed a wait that only passed because of its sleep: a completion needs the sidebar's own tmm to have seen the agent working, and the test was asking a separate `--dump`.
- Made `mise run test` build tmm before the end-to-end tests. It ran `zig build test` only, so they drove whatever binary was built last.
- Drew the name at the top in block letters coloured from the aurora field, with ten letterings to choose from by `TMM_BANNER` while one is picked.
- Gave each agent its own flat name colour, Claude a muted orange and Codex a soft steel blue, and other processes a soft slate rather than white.
- Put a blank row before each session, and made the fold marks arrows: `▼` open, `▶` folded.
- Cut a directory too wide for the sidebar from the left, as `…/name`, so the part that names it stays visible.
- Repaired `tests/integration.py`, which clicked hard-coded rows and had been broken since the sidebar was compacted, unnoticed because it was not in `mise run test`. It now aims at rows by what they say, and it is in the suite.
- Wrote a session's directory once, after its name, instead of after every pane. It is the directory most of the session's panes share; a pane shows its own only when it is somewhere else.
- Drew session names from the blue and teal end of the field, so they stand apart from the purple directories, and stopped dimming an idle agent's name: only its `○` is grey now.
- Coloured the sidebar from a four-corner colour field. The title and headings sweep pink to violet; session names and directories take the field faded; the current server, display and session take it lifted; selection and hover are a faint wash of it. Agent status colours are unchanged.
- Fixed the test screen model. A colour escape split across two reads was drawn as text, which per-cell colour made common, and every relative cursor move and erase was ignored because the final byte was compared as `bytes` against an `int`.

## 10/26/2026

- Made the sidebar compact. Each pane is one row, its directory dimmed after the name rather than on a line of its own, and the blank rows after every heading, between a session and its panes, and after each session are gone; one blank row is left between sections. Headings are bold without the underline.
- Let a session fold to its name. `[-]` before the name folds it and `[+]` opens it, by click or with space. Folded, the name turns green when an agent in it shows a check.

## 10/22/2026

- Ended a reported status when its writer is gone. `@tmm_status` stayed until something cleared it, so an agent killed with `kill -9` read as working forever. tmm now drops a `working`, `blocked` or `idle` record once the pane's own shell runs nothing, read from the process table it already has, and keeps `done` and `error`, as the specification says.
- Brought the status parser to revision 0.4 of the protocol. A report with a bad title, message or id, or over a limit, is discarded whole instead of drawn without the bad part; `kind` and `progress` count only with the states they belong to. A title longer than the row was dropped rather than cut, and the test meant to show it cut passed on the empty string that left.
- Fixed three faults in the Claude Code hook found by comparing it with tuios. Notifications were matched on the human-readable `message` instead of `notification_type`, so they never fired. Approving a permission quickly left `!` showing, because only the next tool call could end a block and the rate limit could drop it. And `Stop` reported idle where the protocol means `done`.
- Recorded how tuios integrates its agent harnesses and implements OSC 7501, in `notes/tuios.md`.
- Returned tmm to being a sidebar controller for tmux. The `--shell` region and the `--panes` compositor are gone, with libghostty-vt, the PNG decoder, the tmux key spelling and the focus key: about 4,700 of 8,800 lines, and the binary from 10.4 MB to 3.2 MB. Getting kitty graphics through a stock tmux meant reimplementing the tmux client one piece at a time, so the terminal work moved to a separate compositor that owns its own pseudoterminals and runs tmux in a window. What stays is what tmm is used for: reading tmux over control mode, the sidebar and its status icons, agent detection, and reported status through the `@tmm_status` pane option.
- Tagged the last commit with both modes `compositor-final`, kept as a stable reference because that code is being adapted elsewhere. `handoff.md`, the compositor's implementation notes, is read from there now.

## 10/21/2026

- Let the sidebar navigate tmm itself in `--panes` mode. Clicking a pane reported "Select a display first" and did nothing, because every navigation path assumed a separate tmux client to drive, and in this mode tmm is the client.
- Named a shifted punctuation key by the character it produces. `prefix )` quietly ran `select-window -t :=9` instead of switching sessions, because a terminal reporting alternate keys sends shift+9 with `9` as the codepoint.
- Made tmm and tmux agree on which pane has the keyboard. tmm focused whichever pane was created first rather than the one tmux had active, and clicking a pane moved only tmm, so a binding like `prefix z` acted on a pane you were not typing in. Both only became visible once bindings worked at all.
- Refused `--panes` on the session tmm is running in, which silently collapsed instead. Sizing that session re-tiles the window holding tmm, so tmm shrank itself from 200 columns to 4 and drew no region at all. It now says so before opening the terminal and lists the sessions that would work. No test caught it because every panes harness launched tmm with `$TMUX` unset.
- Made repeating tmux bindings repeat. Holding ctrl and tapping hjkl to resize after one prefix only moved a column once, and the keys after it went to the program as bytes, where `C-h` is 0x08 and backspaced over the command line. tmm now mirrors the rule tmux applies to `bind -r`, asking the server which keys repeat and how long the window is rather than assuming either.
- Made tmux key bindings work in compositor mode. `C-a h` reached the shell as a 0x01 byte and an `h` before, because tmm writes keys as raw bytes and tmux never saw them as client input. A control-mode client has a real key table, and `send-keys -K` looks a key up in it, so tmm reads the configured prefix from the server and hands those two presses to tmux rather than interpreting any binding itself.

## 10/20/2026

- Decoded the PNG that `kitty icat` and timg transmit, which was being dropped: libghostty-vt leaves its decoder hook null in a library build, so every `f=100` transmission failed to load while chafa worked because it sends raw RGBA.
- Let an agent report what it is doing over OSC 7501 rather than having its screen read, with a transport and a Claude Code hook mapping in `contrib/agent-status`. A hook has no controlling terminal, so the report goes to the pane tty found through tmux.
- Showed a reported title in the sidebar, which was parsed and stored but never drawn.
- Taught the test cleanup to find a tmux server whose temporary directory is already gone. One left over from a previous day inflated a worst-case keystroke measurement from 0.5ms to 77ms.

## 10/18/2026

- Made the focus key a runtime choice, defaulting to ctrl+backtick instead of F12: `--focus-key` names it, `TMM_FOCUS_KEY` sets it once in a profile, and the status line shows whichever key is bound. A key that types something is refused without a modifier, and a spelling tmm cannot use is reported before the terminal is opened.
- Removed a tracked vim swap file, which carried a user name and a host name, and taught every test harness to find the tmm binary and tmux rather than naming an absolute path to one machine.
- Rewrote the published history to drop that swap file and the personal paths and names it and three harnesses carried. Every commit hash changed, so an existing clone has to be reset rather than merged.
- Backfilled the entries below from git history: this file had stopped at 09/10/2026 while the region, the compositor, images and the latency work landed, so those dates are reconstructed from the commits rather than written as the work happened.

## 10/17/2026

- Added program status reporting: a program in a pane says what it is doing over OSC 7501 and the sidebar shows that reported state instead of an inferred one, with progress, a blocked kind, and errors.
- Gave the compositor its own scrollback, reachable with the wheel, and yielded the wheel to a program that asked for mouse reporting.
- Followed the window a session has active, including switches, instead of compositing whichever one was first seen.
- Drew relative and virtual image placements, and answered a program asking how big a cell is both ways it can ask.
- Fixed a double free that crashed every `--panes` exit, and stopped leaking what the control worker had queued when tmm quits.
- Answered `CSI c` in the region, which is what made image viewers stall five seconds per image.
- Gave the shell the keyboard when split mode starts, since split mode is launched to work in.

## 10/16/2026

- Cut keystroke latency in the region: output wakeups are collapsed, queued keys are drained in one pass rather than one per frame, the render state has its own lock, and sending a keystroke takes no lock at all.
- Added native latency probes with the machine and tmux floors measured separately, so a reading can be told from the noise under it.
- Showed the images a program draws in the region, transmitted once per image and placed every frame.
- Delivered key releases to the program inside, which needed asking the outer terminal for the event-types flag.
- Fixed a pane use-after-free, a false divergence report, and a stolen command reply, and updated the vendored libghostty-vt.

## 10/15/2026

- Added the compositor behind `--panes`: one terminal per tmux pane, with tmm as the terminal while tmux keeps the session, the processes and the scrollback.
- Forwarded mouse events into the region, stopped forwarding a modifier pressed on its own, and sent keys the terminal reported without text.
- Extracted `Surface` from `Region` so panes share one terminal implementation, and made tmm nested three deep the region fidelity test.

## 10/14/2026

- Followed the selected display with `list-clients` rather than `display-message`.
- Watched agents in every session instead of only the one the control stream attached.

## 10/13/2026

- Added split-shell mode behind `--shell`: the sidebar on the left, an ordinary shell on the right, with `--split` setting the starting width and the divider draggable.

## 10/09/2026

- Added a pseudoterminal for the terminal region.

## 10/08/2026

- Added an incremental state model maintained from the control-mode event stream, with a dirty set and a reconciliation oracle that checks it against a full collect.
- Served read-only tmux queries from the control client, and skipped agent capture for panes that emitted no output.
- Vendored libghostty-vt instead of depending on the ghostty repository.

## 10/07/2026

- Moved tmux queries onto the control client instead of a subprocess per query, and drove the collector from control-mode events.
- Extracted the control-mode transport into `cmstream`, validated the parser against live tmux, and pinned the toolchain with mise.

## 10/02/2026

- Wired libghostty-vt as the terminal library for the control-mode compositor.

## 10/01/2026

- Added the control-mode protocol and layout parsers.

## 09/17/2026

- Fixed Linux portability and documented which platforms are tested.

## 09/10/2026

- Replaced the local libtmux path dependency with its pinned public GitHub repository.

- Added a transparent cel-shaded README illustration with fictional projects, using WebP in the README and including full-color and smaller PNG versions.

- Licensed tmm under MPL-2.0, matching rawr, while preserving third-party attribution.

## 09/09/2026

- Created the initial tmm controller with libvaxis and Zig 0.16, replacing the handoff's planned QuickTUI frontend.
- Added explicit client selection, session switching, native-navigation reconciliation, project and pane paths, and reported agent metadata.
- Added server selectors, invocation-local display labels, read-only JSON output, background polling, and tmux error diagnostics.
- Added length-prefixed record parsing, client identity validation, unit tests, and isolated two-client integration tests.

- Added mouse hover and click selection; wheel browsing no longer acts as selection.
- Added executable and process ancestry agent detection so Codex panes count without custom metadata.

- Added adjacent lowercase, underlined sessions/displays tabs and highlighted rows without cursor symbols.
- Added display identification messages and session names in the display list. Simplified context IDs and footer, and labeled the active pane working directory.

- Replaced identify-all with a selected-display blink action and `b` shortcut. The marker flashes three times without switching sessions or altering shared styles.

- Changed selected tabs and rows to bright cyan text instead of inverse highlighting.

- Padded the top tabs, moved session paths onto their own line, and added a blank line between session entries with matching mouse hit areas.

- Added a blank line below the display tabs and removed the initial display-selection prompt.

- Replaced tabs with one vertical sidebar containing servers, displays, sessions, paths, and agent status rows.
- Added server discovery and explicit additional servers, clearing display selection when switching servers.
- Made agent rows navigate the selected display to the agent session, window, and pane.
- Removed sidebar IDs, PIDs, and agent counts. Display identification now holds a text label for five seconds without flashing.

- Added inline session renaming on click, with Enter to save, Escape to cancel, editable Unicode names, validation, and retry after tmux errors.

- Removed session paths from the sidebar and placed each agent pane current directory beneath its agent row.

- Added terminal owner names from client process ancestry, including Ghostty, with tty suffixes only when needed.
- Added conservative Codex/Claude screen and title status detection, adapting selected Herdr signals with source attribution.
- Added observed completion receipts and click acknowledgement tied to the displayed pane and agent process identity.

- Listed every pane beneath its session, including ordinary commands, with per-pane directories and click navigation.

- Fixed Claude working-state detection for animated activity lines without interrupt hints and the full Braille title spinner range, with completion transition coverage.

- Added a right-aligned new session action with inline name entry and subtle underline hover feedback on clickable items.

- Coalesced mouse motion and skipped unchanged hover redraws. Added terminal recovery on panic and disabled mouse reporting before worker shutdown.

- Changed new session creation to inherit the selected display pane directory and switch that display into the named session and first window.

- Moved the new session action beside the sessions heading as `sessions   [new]`, with a matching click target.

- Highlighted the selected display current pane and made its directory part of the clickable pane entry.

- Added a left-edge ▸ marker for the current pane and replaced clickable-row hover underlines with brightness changes.

- Added subtle full-entry backgrounds sized to the column content, covering pane names and directories.
- Fixed shutdown hanging when a worker query consumed cancellation by adding an explicit worker stop flag.
