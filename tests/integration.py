#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Only disposable tmux sockets, processes, and files under /tmp are mutated."""
import fcntl
import json
import os
import re
from pathlib import Path
import pty
import select
import signal
import shlex
import struct
import subprocess
import tempfile
import termios
import sys
import time

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'
sys.path.insert(0, str(Path(__file__).resolve().parent))
from screen import Screen  # noqa: E402


def main():
    with tempfile.TemporaryDirectory(prefix='tmm-test-', dir='/tmp') as root:
        socket = root + '/socket'
        other = root + '/other'
        children = []
        terminal_output = {}
        # What each terminal shows, so a click can aim at a row by what it
        # says. Hard-coded row numbers broke on every layout change. Larger
        # than any size the test sets, so nothing wraps.
        screens = {}
        ui_fd = -1

        def command(sock, *args):
            return subprocess.check_output(['tmux', '-S', sock, *args], stderr=subprocess.PIPE, timeout=5).decode()

        def tmux(*args):
            return command(socket, *args)

        def terminal(argv):
            pid, fd = pty.fork()
            if pid == 0:
                os.environ['TERM'] = 'xterm-256color'
                os.environ.pop('TMUX', None)
                os.execvp(argv[0], argv)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
            children.append((pid, fd))
            return pid, fd

        def pump(duration=0.8):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                ready, _, _ = select.select([fd for _, fd in children], [], [], 0.03)
                for fd in ready:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        continue
                    terminal_output.setdefault(fd, bytearray()).extend(data)
                    screens.setdefault(fd, Screen(48, 120)).feed(data)
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def snapshot():
            return json.loads(subprocess.check_output([str(BINARY), '-S', socket, '--dump'], timeout=5))

        def sessions():
            # Exclude control-mode clients: tmm attaches one for the
            # control-mode stream, and it is not a display. tmm's own client
            # listing filters on client_control_mode for the same reason.
            rows = tmux('list-clients', '-F',
                        '#{client_control_mode}|#{client_name}|#{session_name}').splitlines()
            return dict(r.split('|', 2)[1:] for r in rows if r.startswith('0|'))

        def where(client):
            # Where one client currently is. `display-message -c` looks like
            # the way to ask, but -c only selects the client for client
            # formats: the target the formats expand against is the server's
            # current pane, so every client answers the same and the answer
            # does not move when a client navigates. list-clients expands per
            # client. tmm had the same bug; see backend.clients.
            for row in tmux('list-clients', '-F',
                            '#{client_name}|#{pane_id}').splitlines():
                name, _, pane = row.partition('|')
                if name == client:
                    return pane
            raise AssertionError(('client not attached', client))

        def row_of(match, after=None):
            """The 1-based row whose text satisfies `match`, a substring or a
            predicate, optionally only below the row `after` names."""
            test = match if callable(match) else (lambda line: match in line)
            lines = screens[ui_fd].lines()
            start = 0
            if after is not None:
                start = row_of(after) if not isinstance(after, int) else after
            for r in range(start, len(lines)):
                if test(lines[r]):
                    return r + 1
            raise AssertionError(('no row shows', match, lines))

        def first_word(word):
            return lambda line: line.lstrip('▎').split()[:1] == [word]

        # Column 4 is past the hover gutter and a session's fold arrow, so a
        # click lands on the name.
        def click(row, col=4):
            os.write(ui_fd, f'\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m'.encode())
            pump(0.05)

        def until(predicate, what, limit=10):
            """Pump until `predicate` holds, failing with `what` if it never
            does. Every wait for something to happen is one of these rather
            than a fixed sleep: a fixed sleep is the slowest refresh ever seen
            paid on every step, and still a flake on a slower machine."""
            deadline = time.monotonic() + limit
            while True:
                pump(0.03)
                try:
                    if predicate():
                        return
                except (AssertionError, StopIteration, KeyError, subprocess.SubprocessError):
                    pass
                if time.monotonic() > deadline:
                    raise AssertionError(('timed out waiting for', what, screens.get(ui_fd, Screen(1, 1)).text()))

        def settle():
            """A wait for something *not* to happen, which no predicate can
            end early. Long enough for tmm to act on input -- it answers a
            click well inside this -- and no longer."""
            pump(0.3)

        def shows(text):
            return text in screens[ui_fd].text()

        def ui_row(name):
            """The sidebar's own row for an agent. A completion is what *this*
            tmm saw happen, so waits on the states leading up to one read the
            sidebar, not a separate --dump that may have sampled the pane at
            a different moment."""
            return next(([t for t in l.lstrip('▎').split() if t != '▸'] for l in screens[ui_fd].lines() if name in l.lstrip('▎').split()), [])

        def agent_state():
            return next(p for p in snapshot()['panes'] if p['id'] == agent)

        def close_ui(pid, fd):
            os.write(fd, b'q')
            done = 0
            deadline = time.monotonic() + 5
            while done == 0 and time.monotonic() < deadline:
                pump(0.02)
                done, status = os.waitpid(pid, os.WNOHANG)
            assert done == pid, ('UI did not exit', repr(terminal_output[fd][-3000:]))
            assert os.waitstatus_to_exitcode(status) == 0, terminal_output[fd][-4000:]
            children.remove((pid, fd))
            assert b'\x1b[?1002;1003;1004;1006;1016l' in terminal_output[fd], 'mouse reporting was not disabled on exit'
            os.close(fd)

        try:
            strange = root + '/é|tab\tline\nend'
            os.mkdir(strange)
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-c', strange)
            tmux('new-session', '-d', '-s', 'beta', '-c', root)
            tmux('set-option', '-p', '-t', 'alpha', '@agent_hint', 'test-agent')
            tmux('set-option', '-p', '-t', 'alpha', '@agent_state', 'done:123')
            tmux('set-option', '-p', '-t', 'alpha', '@agent_status_text', 'é|done\nnext\tline')
            agent = tmux('new-window', '-d', '-t', 'beta', '-P', '-F', '#{pane_id}', '-n', 'agent', '-c', root).strip()
            tmux('set-option', '-p', '-t', agent, '@agent_hint', 'fake-codex')
            tmux('set-option', '-p', '-t', agent, '@agent_state', 'done:456')
            first_pid, first_fd = terminal(['tmux', '-S', socket, 'attach-session', '-t', 'alpha'])
            second_pid, second_fd = terminal(['tmux', '-S', socket, 'attach-session', '-t', 'alpha'])
            until(lambda: len(snapshot()['clients']) == 2, 'both displays attached')
            initial = snapshot()
            assert any(s['path'] == strange for s in initial['sessions'])
            assert any(p['status'] == 'é|done\nnext\tline' for p in initial['panes'])
            first = next(c['name'] for c in initial['clients'] if c['pid'] == str(first_pid))
            second = next(c['name'] for c in initial['clients'] if c['pid'] == str(second_pid))
            ui_pid, ui_fd = terminal([str(BINARY), '-S', socket, '--client', first])
            until(lambda: shows('µmanager') and shows('fake-codex') and shows('blink'), 'the sidebar')
            # Both displays, both sessions, and all their panes are visible together.
            click(row_of(first_word('blink')))  # blink selected display
            until(lambda: b'tmm display:' in terminal_output.get(first_fd, b''), 'the blink on the selected display')
            assert b'tmm display:' not in terminal_output.get(second_fd, b'')
            # Hover and cancelled clicks do not navigate.
            beta_agent = row_of('fake-codex')
            elsewhere = row_of(first_word('servers'))
            for _ in range(20):
                os.write(ui_fd, b'\x1b[<35;3;%dM' % beta_agent * 100)  # motion burst over beta agent
                pump(0.02)  # drain output while sending, as a real terminal does
            settle()
            assert sessions() == {first: 'alpha', second: 'alpha'}
            os.write(ui_fd, b'\x1b[<0;3;%dM\x1b[<32;3;%dM\x1b[<0;3;%dm' % (beta_agent, elsewhere, elsewhere))
            settle()
            assert sessions()[first] == 'alpha'
            os.write(ui_fd, b'\x1b[<0;3;%dM' % beta_agent)
            pump()  # hold through refresh: a snapshot landing mid-press must not lose it
            os.write(ui_fd, b'\x1b[<0;3;%dm' % beta_agent)
            until(lambda: sessions() == {first: 'beta', second: 'alpha'} and where(first) == agent, 'the agent click to navigate')
            # Ordinary shell panes are also listed and navigate to their exact pane.
            shell_pane = next(p for p in initial['panes'] if not p['agent'])
            assert shell_pane['command'].encode() in terminal_output[ui_fd]
            click(row_of(first_word(shell_pane['command']), after=lambda l: ' beta' in l))
            until(lambda: where(first) == shell_pane['id'], 'the shell pane click to navigate')
            assert sessions() == {first: 'beta', second: 'alpha'}
            click(row_of('fake-codex'))
            until(lambda: where(first) == agent, 'the agent click to navigate back')
            split = tmux('split-window', '-d', '-t', agent, '-P', '-F', '#{pane_id}', '-c', root).strip()
            until(lambda: screens[ui_fd].lines()[row_of('fake-codex')].strip() != '', 'the new split to be listed')
            marker = len(terminal_output[ui_fd])
            click(row_of('fake-codex') + 1)  # the new split, listed after its window's agent
            until(lambda: where(first) == split, 'the split click to navigate')
            assert sessions()[second] == 'alpha'
            until(lambda: '▸'.encode() in terminal_output[ui_fd][marker:], 'the current-pane marker to move on click')
            marker = len(terminal_output[ui_fd])
            tmux('select-pane', '-t', agent)
            until(lambda: '▸'.encode() in terminal_output[ui_fd][marker:], 'the current-pane marker to follow native navigation')
            click(row_of('fake-codex'))
            until(lambda: where(first) == agent, 'the agent click to navigate')
            tmux('kill-pane', '-t', split)
            pane_dir = root + '/pane-current-directory'
            os.mkdir(pane_dir)
            tmux('send-keys', '-t', agent, '-l', 'cd ' + shlex.quote(pane_dir))
            tmux('send-keys', '-t', agent, 'Enter')
            # Whole, though the path is wider than the sidebar: a long
            # directory gives up its start, never the name at its end.
            until(lambda: shows('…') and shows('pane-current-directory'), 'the new directory, cut from the left')
            assert agent_state()['cwd'] == os.path.realpath(pane_dir)

            # Native navigation is reflected, then session click navigates back.
            tmux('switch-client', '-c', first, '-t', '=alpha')
            until(lambda: sessions()[first] == 'alpha', 'native navigation')
            beta_name = row_of(lambda l: l.split()[1:2] == ['beta'])
            click(beta_name)  # clicking the beta name opens the inline editor
            until(lambda: shows('Enter save'), 'the inline editor')
            os.write(ui_fd, b'qjk')  # ordinary text, not sidebar shortcuts
            os.write(ui_fd, b'\x1b')
            until(lambda: shows('j/k move'), 'the editor to close')
            assert {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta'}
            click(beta_name)
            until(lambda: shows('Enter save'), 'the inline editor')
            os.write(ui_fd, b'alpha\r')  # duplicate name must fail without losing the editor
            until(lambda: shows('Enter save') and not shows('saving...'), 'the duplicate to be refused')
            assert {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta'}
            os.write(ui_fd, b'\x15beta renamed \xc3\xa9\r')
            until(lambda: {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta renamed é'}, 'the rename')
            until(lambda: shows('j/k move'), 'the editor to close after saving')
            assert sessions()[first] == 'alpha'  # renaming does not switch displays
            os.write(ui_fd, b'\r')  # keyboard activation still navigates the session
            until(lambda: sessions()[first] == 'beta renamed é', 'Enter to navigate')
            # Small sidebar scrolls without activating entries.
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 15, 32, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            settle()
            os.write(ui_fd, b'\x1b[<65;3;8M')
            settle()
            assert sessions()[first] == 'beta renamed é'
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            settle()
            # A harmless fake agent screen exercises real capture + receipt tracking.
            screen_file = Path(root) / 'screen.txt'
            screen_program = Path(root) / 'screen.py'
            screen_program.write_text("import pathlib,sys,time\np=pathlib.Path(sys.argv[1])\nold=None\nwhile True:\n text=p.read_text()\n if text!=old:\n  sys.stdout.write('\\x1b[2J\\x1b[H'+text);sys.stdout.flush();old=text\n time.sleep(.05)\n")
            idle_screen = '› Ask Codex\n50% context left\n'
            screen_file.write_text(idle_screen)
            tmux('set-option', '-p', '-t', agent, '@agent_hint', 'codex')
            tmux('set-option', '-pu', '-t', agent, '@agent_state')
            tmux('respawn-pane', '-k', '-t', agent, 'python3', str(screen_program), str(screen_file))
            until(lambda: agent_state()['state'] == 'idle', 'the idle codex screen')
            screen_file.write_text('• Working (2s • esc to interrupt)\n' + idle_screen)
            until(lambda: agent_state()['state'] == 'working', 'the working codex screen')
            # The completion rule needs this tmm to have seen working; blocked
            # does not count (src/status.zig, Track.observe).
            until(lambda: ui_row('codex')[:1] == ['●'], 'the sidebar to show codex working')
            assert agent_state()['status_source'] == 'screen', agent_state()
            screen_file.write_text('Press enter to confirm or esc to cancel\n')
            until(lambda: agent_state()['state'] == 'blocked', 'the blocked codex screen')
            until(lambda: ui_row('codex')[:1] == ['!'], 'the sidebar to show codex blocked')
            marker = len(terminal_output[ui_fd])
            screen_file.write_text(idle_screen)
            until(lambda: '✓'.encode() in terminal_output[ui_fd][marker:], 'the codex completion')
            marker = len(terminal_output[ui_fd])
            click(row_of(lambda l: 'codex' in l.split()))
            until(lambda: '○'.encode() in terminal_output[ui_fd][marker:], 'the codex completion to be acknowledged')
            # Claude activity often omits the interrupt hint. Exercise capture,
            # polling, completion, and acknowledgement for that screen shape.
            tmux('set-option', '-p', '-t', agent, '@agent_hint', 'claude')
            claude_idle = '────────────────\n❯ \n────────────────\nshift+tab to cycle\n'
            screen_file.write_text(claude_idle)
            until(lambda: agent_state()['agent'] == 'claude' and agent_state()['state'] == 'idle', 'the idle claude screen')
            screen_file.write_text('✶ Thinking… (2s · ↓ 12 tokens)\n' + claude_idle)
            until(lambda: agent_state()['state'] == 'working', 'the working claude screen')
            until(lambda: ui_row('claude')[:1] == ['●'], 'the sidebar to show claude working')
            assert agent_state()['status_rule'] == 'claude-activity-line', agent_state()
            marker = len(terminal_output[ui_fd])
            screen_file.write_text('✻ Cogitated for 1s\n' + claude_idle)
            until(lambda: '✓'.encode() in terminal_output[ui_fd][marker:], 'the claude completion')
            marker = len(terminal_output[ui_fd])
            click(row_of(lambda l: 'claude' in l.split()))
            until(lambda: '○'.encode() in terminal_output[ui_fd][marker:], 'the claude completion to be acknowledged')
            # The heading itself is not the new-session button. Creation uses
            # an inline field, supports cancellation and duplicate-name retry,
            # and switches only the selected display into an independent session.
            before_create = sessions()
            source_pane = where(first)
            source_cwd = next(p['cwd'] for p in snapshot()['panes'] if p['id'] == source_pane)
            source_windows = tmux('list-windows', '-t', '=beta renamed é', '-F', '#{window_id}')
            heading = row_of(first_word('sessions'))
            click(heading)
            settle()
            assert not shows('Enter save')
            click(heading, 14)
            until(lambda: shows('Enter save'), 'the new-session field')
            os.write(ui_fd, b'cancelled-new-session')
            os.write(ui_fd, b'\x1b')
            until(lambda: shows('j/k move'), 'the new-session field to close')
            assert len(snapshot()['sessions']) == 2
            click(heading, 14)
            until(lambda: shows('Enter save'), 'the new-session field')
            os.write(ui_fd, b'alpha\r')
            until(lambda: shows('Enter save') and not shows('saving...'), 'the duplicate to be refused')
            assert len(snapshot()['sessions']) == 2
            os.write(ui_fd, b'\x15zz new session\r')
            until(lambda: any(s['name'] == 'zz new session' for s in snapshot()['sessions']), 'the new session')
            until(lambda: sessions()[first] == 'zz new session', 'the display to follow the new session')
            created = next(s for s in snapshot()['sessions'] if s['name'] == 'zz new session')
            created_panes = [p for p in snapshot()['panes'] if p['session'] == created['id']]
            assert len(created_panes) == 1 and created_panes[0]['cwd'] == source_cwd
            assert sessions() == {first: 'zz new session', second: before_create[second]}
            assert tmux('list-windows', '-t', '=beta renamed é', '-F', '#{window_id}') == source_windows
            assert tmux('list-windows', '-t', created['id'], '-F', '#{window_name}').strip() == 'zz new session'
            assert not tmux('display-message', '-p', '-t', created['id'], '#{session_group}').strip()
            tmux('switch-client', '-c', first, '-t', '=beta renamed é')
            tmux('kill-session', '-t', created['id'])
            tmux('rename-session', '-t', 'alpha', 'renamed|é')
            tmux('split-window', '-d', '-t', 'renamed|é', '-c', root)
            until(lambda: len(snapshot()['panes']) == 4 and shows('renamed|é'), 'the rename and split to show')
            tmux('detach-client', '-t', first)
            until(lambda: first not in sessions(), 'the detach')
            os.write(ui_fd, b'jj\r')
            until(lambda: b'Display disconnected' in terminal_output[ui_fd], 'the disconnected display to be reported')
            assert sessions() == {second: 'renamed|é'}
            close_ui(ui_pid, ui_fd)
            # Switching servers clears the old display target and its requests.
            command(other, '-f', '/dev/null', 'new-session', '-d', '-s', 'elsewhere', '-c', root)
            ui_pid, ui_fd = terminal([str(BINARY), '-S', socket, '--server-path', other])
            until(lambda: row_of(first_word('other')), 'the second server')
            click(row_of(first_word('other')))  # second server
            until(lambda: shows('elsewhere'), 'the second server sessions')
            assert sessions() == {second: 'renamed|é'}
            command(other, 'kill-server')
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 41, 100, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            # Which error surfaces is a race: tmux usually prints its own
            # diagnostic before the socket is noticed to be gone, and
            # otherwise the write fails first with no diagnostic to read.
            until(lambda: (b'no server running' in terminal_output[ui_fd]
                           or b'error connecting to' in terminal_output[ui_fd]
                           or b'Server connection lost' in terminal_output[ui_fd]), 'the lost server to be reported')
            assert shows('elsewhere') or b'elsewhere' in terminal_output[ui_fd]
            close_ui(ui_pid, ui_fd)
            # Exit at different points in the polling cycle. Cancellation may
            # be consumed inside a query; the explicit stop flag must still win.
            for delay in (0.05, 0.12, 0.25, 0.4, 0.55, 0.7, 0.9, 1.1):
                ui_pid, ui_fd = terminal([str(BINARY), '-S', socket])
                pump(delay)
                close_ui(ui_pid, ui_fd)
            print('PASS: repeated shutdown, live status/completion/acknowledgement, inline create/rename/cancel/duplicate retry, sidebar, shell and agent pane navigation, client isolation, hover/click/scroll, blink, framing, rename, disconnect, server switching, query failure, exit')
        finally:
            for sock in (socket, other):
                subprocess.run(['tmux', '-S', sock, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            for pid, fd in children:
                try:
                    os.kill(pid, signal.SIGKILL)
                    # Bounded, because a blocking waitpid here hangs the whole
                    # run and takes any pending assertion failure with it: the
                    # suite then looks like a timeout with no output at all.
                    # Cleanup must never be the thing that hides the result.
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if os.waitpid(pid, os.WNOHANG)[0]:
                            break
                        time.sleep(0.05)
                    else:
                        print('cleanup: pid', pid, 'did not exit after SIGKILL')
                except (ProcessLookupError, ChildProcessError):
                    pass
                os.close(fd)


if __name__ == '__main__':
    main()
