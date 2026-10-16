#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Force the race: churn tmux with no settle, so operations land mid-collect.

reconcile_live.py settles 700ms after each operation, so a pane created
during a collect is rare: the one failure that prompted this took six suite
runs to appear and never reproduced in forty isolated ones. Here panes are
created and destroyed with no settle, so some of it necessarily happens
while a collect is in flight -- which is the window where the query sees a
pane the model has not been told about yet, because the event saying so is
still in the queue.

Measured against the code without the guard: two of three runs diverged
with `pane_missing`. With it, five of five clean.

Only disposable tmux sockets and files under a temporary directory are
mutated.
"""
import fcntl, os, pty, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time
from pathlib import Path
BIN = str(Path(__file__).resolve().parents[1] / 'zig-out' / 'bin' / 'tmm')
TMUX = shutil.which('tmux') or 'tmux'
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24

with tempfile.TemporaryDirectory(prefix='recon-stress-') as root:
    sock=os.path.join(root,'socket'); log=os.path.join(root,'diverge.log')
    def tmux(*a):
        try: return subprocess.check_output([TMUX,'-S',sock,*a],stderr=subprocess.PIPE,timeout=5).decode()
        except subprocess.CalledProcessError: return ''
    tmux('-f','/dev/null','new-session','-d','-s','alpha','-x','80','-y','24','sleep 600')
    pid,fd=pty.fork()
    if pid==0:
        os.environ['TERM']='xterm-256color'; os.environ['TMM_RECONCILE_LOG']=log
        os.environ.pop('TMUX',None); os.execvp(BIN,[BIN,'-S',sock])
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',40,100,0,0))
    out=bytearray()
    def pump(d=1.0):
        u=time.monotonic()+d
        while time.monotonic()<u:
            for _ in select.select([fd],[],[],0.01)[0]:
                try: r=os.read(fd,65536)
                except OSError: continue
                out.extend(r)
                if b'\x1b[c' in r or b'\x1b[0c' in r: os.write(fd,b'\x1b[?1;2c')
                if b'\x1b[5n' in r: os.write(fd,b'\x1b[0n')
    pump(2.0)
    # No settle: create and destroy as fast as tmux will take it, so some of
    # it necessarily happens while a collect is in flight.
    for i in range(ROUNDS):
        tmux('new-window','-d','-t','alpha','sleep 600')
        tmux('new-window','-d','-t','alpha','sleep 600')
        ws = tmux('list-windows','-t','alpha','-F','#{window_id}').split()
        if len(ws) > 1:
            tmux('split-window','-d','-t',ws[-1],'sleep 600')
            tmux('kill-window','-t',ws[1])
        pump(0.05)
    pump(1.5)
    os.kill(pid,signal.SIGTERM); time.sleep(0.4)
    try: os.waitpid(pid,os.WNOHANG)
    except ChildProcessError: pass
    subprocess.call([TMUX,'-S',sock,'kill-server'],stderr=subprocess.DEVNULL)
    if os.path.exists(log):
        body=open(log).read().strip()
        n = len(body.splitlines())
        print('DIVERGED: %d line(s)' % n)
        for l in body.splitlines()[:6]: print('   ' + l)
        sys.exit(1)
    print('no divergence')
