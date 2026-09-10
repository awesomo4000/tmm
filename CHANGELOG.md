# Changelog

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
