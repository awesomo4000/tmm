#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Only disposable tmux sockets, processes, and files under /tmp are mutated."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import shlex
import struct
import subprocess
import tempfile
import termios
import time

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/tmm'


def main():
    with tempfile.TemporaryDirectory(prefix='tmm-test-', dir='/tmp') as root:
        socket = root + '/socket'
        other = root + '/other'
        children = []
        terminal_output = {}
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
                    if b'\x1b[c' in data or b'\x1b[0c' in data:
                        os.write(fd, b'\x1b[?1;2c')
                    if b'\x1b[5n' in data:
                        os.write(fd, b'\x1b[0n')

        def snapshot():
            return json.loads(subprocess.check_output([str(BINARY), '-S', socket, '--dump'], timeout=5))

        def sessions():
            return dict(line.split('|', 1) for line in tmux('list-clients', '-F', '#{client_name}|#{session_name}').splitlines())

        def click(row, col=3):
            os.write(ui_fd, f'\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m'.encode())
            pump()

        def close_ui(pid, fd):
            os.write(fd, b'q')
            done = 0
            deadline = time.monotonic() + 5
            while done == 0 and time.monotonic() < deadline:
                pump(0.2)
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
            pump()
            initial = snapshot()
            assert len(initial['clients']) == 2
            assert any(s['path'] == strange for s in initial['sessions'])
            assert any(p['status'] == 'é|done\nnext\tline' for p in initial['panes'])
            first = next(c['name'] for c in initial['clients'] if c['pid'] == str(first_pid))
            second = next(c['name'] for c in initial['clients'] if c['pid'] == str(second_pid))
            ui_pid, ui_fd = terminal([str(BINARY), '-S', socket, '--client', first])
            pump(2)
            assert b'tmm : tmux micro manager' in terminal_output[ui_fd]
            assert b'fake-codex' in terminal_output[ui_fd]
            # Both displays, both sessions, and all their panes are visible together.
            click(11)  # blink selected display
            pump(1)
            assert b'tmm display:' in terminal_output[first_fd]
            assert b'tmm display:' not in terminal_output[second_fd]
            # Hover and cancelled clicks do not navigate.
            for _ in range(20):
                os.write(ui_fd, b'\x1b[<35;3;24M' * 100)  # motion burst over beta agent
                pump(0.02)  # drain output while sending, as a real terminal does
            pump()
            assert sessions() == {first: 'alpha', second: 'alpha'}
            os.write(ui_fd, b'\x1b[<0;3;24M\x1b[<32;3;15M\x1b[<0;3;15m')
            pump()
            assert sessions()[first] == 'alpha'
            os.write(ui_fd, b'\x1b[<0;3;24M')
            pump()  # hold through refresh
            os.write(ui_fd, b'\x1b[<0;3;24m')
            pump(1.2)
            assert sessions() == {first: 'beta', second: 'alpha'}, sessions()
            shown = tmux('display-message', '-p', '-c', first, '#{pane_id}').strip()
            assert shown == agent, (shown, agent)
            # Ordinary shell panes are also listed and navigate to their exact pane.
            shell_pane = next(p for p in initial['panes'] if not p['agent'])
            assert shell_pane['command'].encode() in terminal_output[ui_fd]
            click(23)  # the pane directory is part of the clickable entry
            pump(1.2)
            assert sessions() == {first: 'beta', second: 'alpha'}
            assert tmux('display-message', '-p', '-c', first, '#{pane_id}').strip() == shell_pane['id']
            click(24)
            pump(1.2)
            assert tmux('display-message', '-p', '-c', first, '#{pane_id}').strip() == agent
            split = tmux('split-window', '-d', '-t', agent, '-P', '-F', '#{pane_id}', '-c', root).strip()
            pump(1.2)
            marker = len(terminal_output[ui_fd])
            click(27)  # directory beneath the new split's row
            pump(1.2)
            assert tmux('display-message', '-p', '-c', first, '#{pane_id}').strip() == split
            assert sessions()[second] == 'alpha'
            assert '▸'.encode() in terminal_output[ui_fd][marker:], 'current-pane marker did not move on click'
            marker = len(terminal_output[ui_fd])
            tmux('select-pane', '-t', agent)
            pump(1.2)
            assert '▸'.encode() in terminal_output[ui_fd][marker:], 'current-pane marker did not follow native navigation'
            click(24)
            pump(1.2)
            assert tmux('display-message', '-p', '-c', first, '#{pane_id}').strip() == agent
            tmux('kill-pane', '-t', split)
            pump()
            pane_dir = root + '/pane-current-directory'
            os.mkdir(pane_dir)
            tmux('send-keys', '-t', agent, '-l', 'cd ' + shlex.quote(pane_dir))
            tmux('send-keys', '-t', agent, 'Enter')
            pump(1.2)
            live_pane = next(p for p in snapshot()['panes'] if p['id'] == agent)
            assert live_pane['cwd'] == os.path.realpath(pane_dir)
            assert b'pane-current-directory' in terminal_output[ui_fd]

            # Native navigation is reflected, then session click navigates back.
            tmux('switch-client', '-c', first, '-t', '=alpha')
            pump()
            click(20)  # clicking the beta name opens the inline editor
            os.write(ui_fd, b'qjk')  # ordinary text, not sidebar shortcuts
            pump()
            os.write(ui_fd, b'\x1b')
            pump()
            assert {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta'}
            click(20)
            os.write(ui_fd, b'alpha\r')  # duplicate name must fail without losing the editor
            pump(1.2)
            assert {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta'}
            os.write(ui_fd, b'\x15beta renamed \xc3\xa9\r')
            pump(1.2)
            assert {s['name'] for s in snapshot()['sessions']} == {'alpha', 'beta renamed é'}
            assert sessions()[first] == 'alpha'  # renaming does not switch displays
            os.write(ui_fd, b'\r')  # keyboard activation still navigates the session
            pump()
            assert sessions()[first] == 'beta renamed é'
            # Small sidebar scrolls without activating entries.
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 15, 32, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            pump()
            os.write(ui_fd, b'\x1b[<65;3;8M')
            pump()
            assert sessions()[first] == 'beta renamed é'
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            pump()
            # A harmless fake agent screen exercises real capture + receipt tracking.
            screen_file = Path(root) / 'screen.txt'
            screen_program = Path(root) / 'screen.py'
            screen_program.write_text("import pathlib,sys,time\np=pathlib.Path(sys.argv[1])\nold=None\nwhile True:\n text=p.read_text()\n if text!=old:\n  sys.stdout.write('\\x1b[2J\\x1b[H'+text);sys.stdout.flush();old=text\n time.sleep(.05)\n")
            idle_screen = '› Ask Codex\n50% context left\n'
            screen_file.write_text(idle_screen)
            tmux('set-option', '-p', '-t', agent, '@agent_hint', 'codex')
            tmux('set-option', '-pu', '-t', agent, '@agent_state')
            tmux('respawn-pane', '-k', '-t', agent, 'python3', str(screen_program), str(screen_file))
            pump(1.5)
            assert next(p for p in snapshot()['panes'] if p['id'] == agent)['state'] == 'idle'
            screen_file.write_text('• Working (2s • esc to interrupt)\n' + idle_screen)
            pump(1.2)
            detected = next(p for p in snapshot()['panes'] if p['id'] == agent)
            assert detected['state'] == 'working' and detected['status_source'] == 'screen', detected
            screen_file.write_text('Press enter to confirm or esc to cancel\n')
            pump()
            assert next(p for p in snapshot()['panes'] if p['id'] == agent)['state'] == 'blocked'
            marker = len(terminal_output[ui_fd])
            screen_file.write_text(idle_screen)
            pump(1.8)
            assert '✓'.encode() in terminal_output[ui_fd][marker:], ('completion was not displayed', repr(terminal_output[ui_fd][marker:]), next(p for p in snapshot()['panes'] if p['id'] == agent))
            marker = len(terminal_output[ui_fd])
            click(24)
            pump()
            assert '○'.encode() in terminal_output[ui_fd][marker:], 'completion was not acknowledged'
            # Claude activity often omits the interrupt hint. Exercise capture,
            # polling, completion, and acknowledgement for that screen shape.
            tmux('set-option', '-p', '-t', agent, '@agent_hint', 'claude')
            claude_idle = '────────────────\n❯ \n────────────────\nshift+tab to cycle\n'
            screen_file.write_text(claude_idle)
            pump(1.2)
            screen_file.write_text('✶ Thinking… (2s · ↓ 12 tokens)\n' + claude_idle)
            pump(1.2)
            detected = next(p for p in snapshot()['panes'] if p['id'] == agent)
            assert detected['state'] == 'working' and detected['status_rule'] == 'claude-activity-line', detected
            marker = len(terminal_output[ui_fd])
            screen_file.write_text('✻ Cogitated for 1s\n' + claude_idle)
            pump(1.8)
            assert '✓'.encode() in terminal_output[ui_fd][marker:], 'Claude completion was not displayed'
            marker = len(terminal_output[ui_fd])
            click(24)
            pump()
            assert '○'.encode() in terminal_output[ui_fd][marker:], 'Claude completion was not acknowledged'
            # The heading itself is not the new-session button. Creation uses
            # an inline field, supports cancellation and duplicate-name retry,
            # and switches only the selected display into an independent session.
            before_create = sessions()
            source_pane = tmux('display-message', '-p', '-c', first, '#{pane_id}').strip()
            source_cwd = next(p['cwd'] for p in snapshot()['panes'] if p['id'] == source_pane)
            source_windows = tmux('list-windows', '-t', '=beta renamed é', '-F', '#{window_id}')
            marker = len(terminal_output[ui_fd])
            click(13)
            assert b'Enter save' not in terminal_output[ui_fd][marker:]
            click(13, 14)
            os.write(ui_fd, b'cancelled-new-session')
            os.write(ui_fd, b'\x1b')
            pump()
            assert len(snapshot()['sessions']) == 2
            click(13, 14)
            os.write(ui_fd, b'alpha\r')
            pump(1.2)
            assert len(snapshot()['sessions']) == 2
            os.write(ui_fd, b'\x15zz new session\r')
            pump(1.2)
            created = next(s for s in snapshot()['sessions'] if s['name'] == 'zz new session')
            created_panes = [p for p in snapshot()['panes'] if p['session'] == created['id']]
            assert len(created_panes) == 1 and created_panes[0]['cwd'] == source_cwd
            assert sessions() == {first: 'zz new session', second: before_create[second]}
            assert tmux('list-windows', '-t', '=beta renamed é', '-F', '#{window_id}') == source_windows
            assert tmux('list-windows', '-t', created['id'], '-F', '#{window_name}').strip() == 'zz new session'
            assert not tmux('display-message', '-p', '-t', created['id'], '#{session_group}').strip()
            tmux('switch-client', '-c', first, '-t', '=beta renamed é')
            tmux('kill-session', '-t', created['id'])
            pump()
            tmux('rename-session', '-t', 'alpha', 'renamed|é')
            tmux('split-window', '-d', '-t', 'renamed|é', '-c', root)
            pump()
            assert len(snapshot()['panes']) == 4
            tmux('detach-client', '-t', first)
            pump()
            os.write(ui_fd, b'jj\r')
            pump()
            assert sessions() == {second: 'renamed|é'}
            assert b'Target disconnected' in terminal_output[ui_fd]
            close_ui(ui_pid, ui_fd)
            # Switching servers clears the old display target and its requests.
            command(other, '-f', '/dev/null', 'new-session', '-d', '-s', 'elsewhere', '-c', root)
            ui_pid, ui_fd = terminal([str(BINARY), '-S', socket, '--server-path', other])
            pump(2)
            click(6)  # second server
            pump()
            assert b'elsewhere' in terminal_output[ui_fd]
            assert sessions() == {second: 'renamed|é'}
            command(other, 'kill-server')
            pump()
            fcntl.ioctl(ui_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 41, 100, 0, 0))
            os.kill(ui_pid, signal.SIGWINCH)
            pump()
            output = terminal_output[ui_fd]
            assert b'no server running' in output or b'error connecting to' in output, output[-2000:]
            assert b'elsewhere' in output
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
                    os.waitpid(pid, 0)
                except (ProcessLookupError, ChildProcessError):
                    pass
                os.close(fd)


if __name__ == '__main__':
    main()
