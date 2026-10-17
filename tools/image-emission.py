#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""What do real image viewers emit, and does tmm have to understand it?

tmm draws kitty graphics placements out of libghostty-vt storage. Three
location kinds exist: a pin (a cell in the grid), relative (an offset from
another placement), and virtual -- a placement with no position of its own,
which the program positions afterwards by writing U+10EEEE placeholder cells
whose diacritics carry the image id and the row and column. tmm resolves pins
and relatives. Virtual is unimplemented, because implementing it means
scanning every cell of every frame for placeholders inside a blit that costs
0.25ms, and it was not worth paying for a protocol nothing used.

So this measures whether anything real uses it, and measures it in three
layers, because a viewer decides what to emit from what the terminal admits
to supporting:

    bare   the viewer under a pty that answers as a kitty-class terminal
    tmux   the same, inside tmux with passthrough on
    tmm    the same, inside a tmm region

Two things are recorded per layer. The geometry a child process sees, because
a viewer that reads ws_xpixel == 0 and gets no answer to CSI 14 t concludes
the terminal has no graphics and emits text instead -- a refusal, not a
preference, and it is easy to mistake one for the other. And the bytes, which
are classified by protocol and by kitty action, so a virtual placement is
named as one rather than counted as an APC.

Only disposable sockets, processes, and files under /tmp are mutated.
"""
import argparse
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import zlib

ROWS, COLS, SPLIT = 40, 170, 30
CELL_W, CELL_H = 10, 20
ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/tmm'

PLACEHOLDER = '\U0010eeee'.encode()       # U+10EEEE, the virtual placement cell
DIACRITICS = re.compile(rb'\xcc[\x80-\xbf]|\xcd[\x80-\xaf]')
# A viewer that cannot find pixel geometry says so; the wording differs per
# viewer but every one of them is a refusal and not a choice of protocol.
REFUSALS = (b'does not support reporting screen sizes in pixels',
            b'missing or unsuitable terminal',
            b'unsupported terminal')


def png(width=64, height=64):
    """A PNG with no encoder dependency, so the probe runs anywhere."""
    rows = b''
    for y in range(height):
        rows += b'\x00' + bytes(
            v for x in range(width)
            for v in (x * 255 // (width - 1), y * 255 // (height - 1), 128))

    def chunk(kind, body):
        data = kind + body
        return struct.pack('>I', len(body)) + data + struct.pack('>I', zlib.crc32(data))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows))
            + chunk(b'IEND', b''))


def answer(fd, data, state):
    """Reply as a kitty-class terminal would.

    Each viewer asks a different subset, so all of them are answered and the
    ones that fired are reported: a capture with no graphics in it means
    something different when nothing was ever asked.
    """
    fired = state.setdefault('fired', [])

    def send(name, reply):
        fired.append(name)
        os.write(fd, reply)

    if re.search(rb'\x1b\[[0-9]*c', data):
        send('DA1', b'\x1b[?62;4c')                        # 4 = sixel
    if re.search(rb'\x1b\[>[0-9]*c', data):
        send('DA2', b'\x1b[>1;4000;13c')
    if b'\x1b[>q' in data:
        send('XTVERSION', b'\x1bP>|kitty(0.42.0)\x1b\\')
    if b'\x1b[16t' in data:
        send('cell-px', b'\x1b[6;%d;%dt' % (CELL_H, CELL_W))
    if b'\x1b[14t' in data:
        send('text-px', b'\x1b[4;%d;%dt' % (ROWS * CELL_H, COLS * CELL_W))
    if b'\x1b[18t' in data:
        send('text-cells', b'\x1b[8;%d;%dt' % (ROWS, COLS))
    if b'\x1b[6n' in data:
        send('CPR', b'\x1b[1;1R')
    if b'\x1b[5n' in data:
        send('DSR', b'\x1b[0n')
    if b'\x1b[?u' in data:
        send('kbd', b'\x1b[?0u')
    if b']10;?' in data:
        send('fg', b'\x1b]10;rgb:ffff/ffff/ffff\x1b\\')
    if b']11;?' in data:
        send('bg', b'\x1b]11;rgb:0000/0000/0000\x1b\\')
    # The kitty graphics support query. Viewers probe each transfer mode they
    # could use -- direct, temp file (t=t), shared memory (t=s) -- and choose
    # from the answers, so answering all of them is answering as kitty does.
    for m in re.finditer(rb'\x1b_G([^\x1b]*?)a=q([^\x1b]*?)(?:\x1b\\|$)', data):
        head = (m.group(1) + m.group(2)).partition(b';')[0]
        found = re.search(rb'i=(\d+)', head)
        send('kitty-q', b'\x1b_Gi=%s;OK\x1b\\' % (found.group(1) if found else b'1'))


def run(argv, env_extra, duration, cols=COLS):
    """Run argv under a pty answering as a kitty-class terminal."""
    pid, fd = pty.fork()
    if pid == 0:
        for stale in ('TMUX', 'TMUX_PANE'):
            os.environ.pop(stale, None)
        os.environ['COLORTERM'] = 'truecolor'
        os.environ['KITTY_WINDOW_ID'] = '1'
        os.environ.setdefault('TERM', 'xterm-kitty')
        os.environ.update(env_extra)
        try:
            os.execvp(argv[0], argv)
        except Exception:
            os._exit(127)
    # ws_xpixel and ws_ypixel are not optional here. A viewer that reads
    # zeroes decides the terminal has no graphics and falls back to text,
    # which is what the first run of this probe measured by mistake.
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', ROWS, cols, cols * CELL_W, ROWS * CELL_H))
    seen, state = bytearray(), {}
    until = time.monotonic() + duration
    while time.monotonic() < until:
        ready, _, _ = select.select([fd], [], [], 0.02)
        for f in ready:
            try:
                data = os.read(f, 1 << 18)
            except OSError:
                data = b''
            if not data:
                until = 0
                break
            seen.extend(data)
            answer(fd, data, state)
    for sig in (15, 9):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
        time.sleep(0.15)
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    os.close(fd)
    return bytes(seen), state.get('fired', [])


def classify(out):
    """Name the graphics protocol and the kitty actions present in a stream."""
    report = {'bytes': len(out)}
    apcs = [a for a in re.findall(rb'\x1b_G([^\x1b]*)', out) if a]
    keys = {}
    for head in (a.partition(b';')[0] for a in apcs):
        for pair in head.split(b','):
            k, _, v = pair.partition(b'=')
            if k:
                keys.setdefault(k.decode(), set()).add(v.decode())
    report['kitty_apcs'] = len(apcs)
    report['kitty_keys'] = {k: sorted(v) for k, v in sorted(keys.items())}
    report['sixel'] = len(re.findall(rb'\x1bP[0-9;]*q', out))
    report['iterm2'] = len(re.findall(rb'\x1b]1337;File=', out))
    report['placeholders'] = out.count(PLACEHOLDER)
    report['diacritics'] = len(DIACRITICS.findall(out))
    report['halfblocks'] = (out.count('▀'.encode())
                            + out.count('▄'.encode()))
    report['passthrough'] = len(re.findall(rb'\x1bPtmux;', out))
    report['refused'] = next((r.decode() for r in REFUSALS if r in out), None)

    # U=1 on the transmission and placeholder cells in the text are two halves
    # of one mechanism; either alone means tmm has to handle it.
    # A virtual placement declares its extent in cells as c= by r=, and the
    # program then writes exactly that many placeholder cells per draw. The
    # ratio is a cross-check on the counting: it should come out a whole
    # number of redraws, and anything else means this is miscounting.
    try:
        cells = int(sorted(keys['c'])[0]) * int(sorted(keys['r'])[0])
    except (KeyError, ValueError):
        cells = 0
    report['declared_cells'] = cells
    report['redraws'] = round(report['placeholders'] / cells, 2) if cells else 0

    declared = '1' in keys.get('U', set())
    report['needs_virtual'] = declared or report['placeholders'] > 0
    if declared and report['placeholders']:
        report['verdict'] = ('virtual: U=1 and %d placeholder cells'
                             % report['placeholders'])
    elif report['placeholders']:
        report['verdict'] = 'placeholder cells with no U=1'
    elif declared:
        report['verdict'] = 'U=1 declared, no placeholder cells'
    elif report['kitty_apcs']:
        report['verdict'] = ('kitty direct (a=%s)'
                             % ','.join(sorted(keys.get('a', {'-'}))))
    elif report['sixel']:
        report['verdict'] = 'sixel'
    elif report['iterm2']:
        report['verdict'] = 'iterm2 osc 1337'
    elif report['refused']:
        report['verdict'] = 'refused: %s' % report['refused']
    elif report['halfblocks']:
        report['verdict'] = 'text fallback (half blocks)'
    else:
        report['verdict'] = 'no graphics, no fallback seen'
    return report


def geometry(layer, socket_root, duration):
    """What a child process sees for size, which is what a viewer acts on.

    Answered to a file rather than to the screen, because inside tmm the
    screen is redrawn cell by cell with SGR between the digits.
    """
    answer_path = os.path.join(socket_root, 'geom-%s.txt' % layer)
    probe = os.path.join(socket_root, 'geom-%s.py' % layer)
    Path(probe).write_text(
        'import fcntl, termios, struct, sys, time, os\n'
        'w = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\\0" * 8)\n'
        'r, c, x, y = struct.unpack("HHHH", w)\n'
        'open(%r, "w").write("%%dx%%d cells, %%dx%%d px" %% (c, r, x, y))\n'
        'time.sleep(300)\n' % answer_path)
    script = os.path.join(socket_root, 'geom-%s.sh' % layer)
    Path(script).write_text('#!/bin/sh\nexec %s %s\n' % (sys.executable, probe))
    os.chmod(script, 0o755)
    argv, env = wrap(layer, script, socket_root, 'geom')
    if argv is None:
        return 'n/a'
    sock = env.pop('_sock', None)
    run(argv, env, duration, cols=COLS - SPLIT - 1 if layer == 'tmm' else COLS)
    kill(sock)
    try:
        return Path(answer_path).read_text().strip()
    except OSError:
        return 'no answer'


def kill(sock):
    if sock:
        subprocess.run(['tmux', '-S', sock, 'kill-server'],
                       capture_output=True, timeout=10)


def tmux_conf(socket_root):
    conf = os.path.join(socket_root, 'tmux.conf')
    # Without passthrough tmux drops an APC it does not understand, and a
    # viewer that notices picks another protocol, so the tmux layer would
    # measure the refusal rather than the preference.
    Path(conf).write_text('set -g allow-passthrough on\n')
    return conf


def wrap(layer, script, socket_root, tag):
    """Build the argv that runs script inside the named layer."""
    if layer == 'bare':
        return [script], {}
    sock = os.path.join(socket_root, '%s-%s-%d' % (layer, tag, time.time_ns() % 100000))
    conf = tmux_conf(socket_root)
    if layer == 'tmux':
        # tmux needs a terminfo entry for its own TERM or it refuses to start,
        # and xterm-kitty is not present everywhere.
        return (['tmux', '-S', sock, '-f', conf, 'new-session', script],
                {'TERM': 'xterm-256color', '_sock': sock})
    if layer == 'tmm':
        if not BINARY.exists():
            return None, {}
        subprocess.run(['tmux', '-S', sock, '-f', conf,
                        'new-session', '-d', '-s', 'p'],
                       capture_output=True, timeout=10)
        return ([str(BINARY), '-S', sock, '--shell', '--split', str(SPLIT)],
                {'TERM': 'xterm-256color', 'SHELL': script, '_sock': sock})
    raise AssertionError(layer)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--duration', type=float, default=5.0,
                    help='seconds to let each run proceed')
    ap.add_argument('--layers', default='bare,tmux,tmm')
    ap.add_argument('--save', metavar='DIR',
                    help='write each captured stream for inspection')
    args = ap.parse_args()

    candidates = [
        ('kitten-icat', ['kitten', 'icat', '--align', 'left']),
        ('timg', ['timg', '-pk', '-g80x40']),
        ('chafa', ['chafa', '-f', 'kitty', '--size', '40x20']),
        ('chafa-auto', ['chafa', '--size', '40x20']),
    ]
    viewers = [(n, a) for n, a in candidates if shutil.which(a[0])]
    missing = sorted({a[0] for n, a in candidates if not shutil.which(a[0])})
    if not viewers:
        raise SystemExit('no image viewers installed; tried %s' % ', '.join(missing))
    wanted = args.layers.split(',')

    rows, geom = [], {}
    with tempfile.TemporaryDirectory(prefix='tmm-emission-', dir='/tmp') as root:
        image = os.path.join(root, 'probe.png')
        Path(image).write_bytes(png())
        for layer in wanted:
            geom[layer] = geometry(layer, root, args.duration)
        for name, argv in viewers:
            script = os.path.join(root, name + '.sh')
            Path(script).write_text('#!/bin/sh\n%s %s\nsleep 300\n'
                                    % (' '.join(argv), image))
            os.chmod(script, 0o755)
            for layer in wanted:
                wrapped, env = wrap(layer, script, root, name)
                if wrapped is None:
                    continue
                sock = env.pop('_sock', None)
                cols = COLS - SPLIT - 1 if layer == 'tmm' else COLS
                out, fired = run(wrapped, env, args.duration, cols=cols)
                kill(sock)
                report = classify(out)
                report.update(viewer=name, layer=layer, fired=fired)
                rows.append(report)
                if args.save:
                    d = Path(args.save)
                    d.mkdir(parents=True, exist_ok=True)
                    (d / ('%s-%s.bin' % (name, layer))).write_bytes(out)

    print('geometry a child process sees:')
    for layer in wanted:
        print('  %-5s %s' % (layer, geom.get(layer, '?')))
    print()
    width = max(len(r['viewer']) for r in rows)
    print('%-*s  %-5s  %9s  %5s  %6s  %5s  %7s  %s'
          % (width, 'viewer', 'layer', 'bytes', 'apcs', 'placeh', 'cells',
             'redraws', 'verdict'))
    for r in rows:
        print('%-*s  %-5s  %9d  %5d  %6d  %5d  %7s  %s'
              % (width, r['viewer'], r['layer'], r['bytes'], r['kitty_apcs'],
                 r['placeholders'], r['declared_cells'],
                 r['redraws'] or '-', r['verdict']))
    print()
    for r in rows:
        if r['kitty_keys']:
            print('%s/%s keys: %s' % (r['viewer'], r['layer'],
                  ', '.join('%s=%s' % (k, '|'.join(v))
                            for k, v in r['kitty_keys'].items())))
    print()
    for r in rows:
        print('%s/%s answered: %s' % (r['viewer'], r['layer'],
              ', '.join(dict.fromkeys(r['fired'])) or 'nothing was asked'))
    if missing:
        print('\nnot installed, not measured: %s' % ', '.join(missing))

    wants = [r for r in rows if r['needs_virtual']]
    print('\nvirtual placements: %s'
          % ('used by ' + ', '.join('%s/%s' % (r['viewer'], r['layer'])
                                    for r in wants) if wants
             else 'not used by any viewer measured, in any layer'))


if __name__ == '__main__':
    main()
