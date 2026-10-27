import re
import fcntl, os, pty, select, shutil, struct, subprocess, tempfile, termios, time, signal, sys
# Found rather than spelled out: a path to one checkout runs nowhere else.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'zig-out', 'bin', 'tmm')
# Resolved now, and absolutely: a wrapper named tmux goes on PATH below,
# so anything resolved later would be that wrapper calling itself.
REAL = shutil.which('tmux') or 'tmux'
with tempfile.TemporaryDirectory(prefix='spawnm-') as root:
    sock = os.path.join(root, 'socket')
    log = os.path.join(root, 'spawns.log')
    wrap = os.path.join(root, 'tmux')
    with open(wrap, 'w') as f:
        f.write('#!/bin/bash\necho "$@" >> %s\nexec %s "$@"\n' % (log, REAL))
    os.chmod(wrap, 0o755)
    subprocess.check_call([REAL, '-S', sock, '-f', '/dev/null', 'new-session',
                           '-d', '-s', 'alpha', '-x', '80', '-y', '24', 'sleep 300'])
    open(log, 'w').close()
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ['PATH'] = root + ':' + os.environ['PATH']
        os.environ.pop('TMUX', None)
        os.execvp(BIN, [BIN, '-S', sock])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
    import select
    out = bytearray()
    until = time.monotonic() + 6.0
    while time.monotonic() < until:
        ready, _, _ = select.select([fd], [], [], 0.03)
        for _f in ready:
            try:
                r = os.read(fd, 65536)
            except OSError:
                continue
            out += r
            # vaxis queryTerminal blocks until these are answered.
            if b'\x1b[c' in r or b'\x1b[0c' in r:
                os.write(fd, b'\x1b[?1;2c')
            if b'\x1b[5n' in r:
                os.write(fd, b'\x1b[0n')
    os.kill(pid, signal.SIGTERM)
    time.sleep(0.4)
    try: os.waitpid(pid, os.WNOHANG)
    except ChildProcessError: pass
    rendered = 'µmanager'.encode() in re.sub(rb'\x1b\[[0-9;:]*m', b'', bytes(out))
    lines = [l for l in open(log).read().splitlines() if l.strip()]
    subprocess.call([REAL, '-S', sock, 'kill-server'],
                    stderr=subprocess.DEVNULL)
    print('tmm rendered:        %s' % rendered)
    print('ran for:             6.0s  (>= 12 heartbeat collects)')
    print('tmux spawns total:   %d' % len(lines))
    kinds = {}
    for l in lines:
        parts = l.split()
        key = ' '.join(p for p in parts if not p.startswith('/') and p != '-S')[:48]
        kinds[key] = kinds.get(key, 0) + 1
    for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print('  %3d  %s' % (v, k))
