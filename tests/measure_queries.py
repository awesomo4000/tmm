#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Counts tmux queries per collect, with three idle agent panes.

Only disposable tmux sockets and files under a temporary directory are mutated.
Agent capture is two queries per agent pane per pass and was two thirds of the
cost before output-driven skipping, so this is the number to watch when
changing how much each pass asks tmux.

Expect a few passes at the full count while panes settle (the sample budget in
backend.zig), then a floor of the structural queries alone.
"""
import re
import fcntl, os, pty, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time
from pathlib import Path
# Found rather than spelled out: a path to one checkout runs nowhere else,
# and a path to one tmux runs on nobody else's machine.
BIN=str(Path(__file__).resolve().parents[1] / 'zig-out' / 'bin' / 'tmm'); TMUX=shutil.which('tmux') or 'tmux'
with tempfile.TemporaryDirectory(prefix='qm-') as root:
    sock=os.path.join(root,'socket'); qlog=os.path.join(root,'q.log')
    def tmux(*a): return subprocess.check_output([TMUX,'-S',sock,*a],stderr=subprocess.PIPE,timeout=5).decode()
    tmux('-f','/dev/null','new-session','-d','-s','alpha','-x','80','-y','24','sleep 600')
    for i in range(3):
        p=tmux('new-window','-d','-t','alpha','-P','-F','#{pane_id}','sleep 600').strip()
        tmux('set-option','-p','-t',p,'@agent_hint','claude')
    pid,fd=pty.fork()
    if pid==0:
        os.environ['TERM']='xterm-256color'; os.environ['TMM_QUERY_LOG']=qlog
        os.environ.pop('TMUX',None); os.execvp(BIN,[BIN,'-S',sock])
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',40,100,0,0))
    out=bytearray(); u=time.monotonic()+6.0
    while time.monotonic()<u:
        for _ in select.select([fd],[],[],0.03)[0]:
            try: r=os.read(fd,65536)
            except OSError: continue
            out.extend(r)
            if b'\x1b[c' in r or b'\x1b[0c' in r: os.write(fd,b'\x1b[?1;2c')
            if b'\x1b[5n' in r: os.write(fd,b'\x1b[0n')
    os.kill(pid,signal.SIGTERM); time.sleep(0.5)
    try: os.waitpid(pid,os.WNOHANG)
    except ChildProcessError: pass
    subprocess.call([TMUX,'-S',sock,'kill-server'],stderr=subprocess.DEVNULL)
    assert b'tmm : tmux micro manager' in re.sub(rb'\x1b\[[0-9;:]*m', b'', bytes(out)), 'did not render'
    counts=[int(l) for l in open(qlog).read().split() if l.strip().isdigit()]
    # counts are cumulative per Connection, which is recreated each collect
    print('collects: %d' % len(counts))
    print('queries per collect: %s' % counts[:12])
    if not counts: raise SystemExit('FAIL: no query counts recorded')
    print('mean: %.1f   total over 6s: %d' % (sum(counts)/len(counts), sum(counts)))
    settled = counts[4:]
    if settled and max(settled) > 4:
        raise SystemExit('FAIL: idle agent panes are still being captured: %s' % settled)
    print('queries OK: settled at %d per collect with 3 idle agents' % (settled[0] if settled else counts[-1]))
