#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Checks the incremental model against full queries, in the running app.

Only disposable tmux sockets and files under a temporary directory are mutated.
Runs tmm with TMM_RECONCILE_LOG set, drives tmux through the operations the
event-driven model has to track, and fails if the model ever disagreed with a
full query about which sessions and panes exist or where they live.

This is the oracle described in reconcile.zig: full queries are cheap now that
they ride a control client, so one per collect is affordable as a check.
"""
import fcntl, os, pty, select, shutil, signal, struct, subprocess, tempfile, termios, time
# Found rather than spelled out: a path to one checkout runs nowhere else,
# and a path to one tmux runs on nobody else's machine.
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__))); BIN=os.path.join(ROOT,'zig-out','bin','tmm'); TMUX=shutil.which('tmux') or 'tmux'
with tempfile.TemporaryDirectory(prefix='recon-') as root:
    sock=os.path.join(root,'socket'); log=os.path.join(root,'diverge.log')
    def tmux(*a): return subprocess.check_output([TMUX,'-S',sock,*a],stderr=subprocess.PIPE,timeout=5).decode()
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
            for _ in select.select([fd],[],[],0.03)[0]:
                try: r=os.read(fd,65536)
                except OSError: continue
                out.extend(r)
                if b'\x1b[c' in r or b'\x1b[0c' in r: os.write(fd,b'\x1b[?1;2c')
                if b'\x1b[5n' in r: os.write(fd,b'\x1b[0n')
    pump(2.0)
    assert b'tmm : tmux micro manager' in out, 'tmm did not render'
    # Churn: the operations the incremental model must track.
    ops=[]
    for i in range(3):
        tmux('new-window','-d','-t','alpha','sleep 600'); ops.append('new-window'); pump(0.7)
    tmux('new-session','-d','-s','beta','-c',root,'sleep 600'); ops.append('new-session'); pump(0.7)
    tmux('rename-session','-t','beta','gamma'); ops.append('rename-session'); pump(0.7)
    w=tmux('list-windows','-t','alpha','-F','#{window_id}').split()[-1]
    tmux('split-window','-d','-t',w,'sleep 600'); ops.append('split-window'); pump(0.7)
    panes=tmux('list-panes','-t',w,'-F','#{pane_id}').split()
    tmux('kill-pane','-t',panes[-1]); ops.append('kill-pane'); pump(0.7)
    tmux('kill-window','-t',w); ops.append('kill-window'); pump(0.7)
    tmux('kill-session','-t','gamma'); ops.append('kill-session'); pump(1.2)
    os.kill(pid,signal.SIGTERM); time.sleep(0.4)
    try: os.waitpid(pid,os.WNOHANG)
    except ChildProcessError: pass
    subprocess.call([TMUX,'-S',sock,'kill-server'],stderr=subprocess.DEVNULL)
    print('operations driven: '+', '.join(ops))
    if os.path.exists(log):
        body=open(log).read().strip()
        raise SystemExit('FAIL: incremental model diverged from a full query:\n'
                         + '\n'.join('  '+l for l in body.splitlines()[:20]))
    print('reconcile OK: no divergence across %d operations (%s)'
          % (len(ops), ', '.join(ops)))
