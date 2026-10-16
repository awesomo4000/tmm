#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A key scope: blasts the screen and shows every key that arrives through it.

Run it bare in your terminal first to see what that terminal does on its
own, then run it inside tmm's region and compare. The numbers only mean
something next to each other, because most of what they measure belongs to
the terminal and the keyboard, not to whatever is in between.

What each number is, exactly:

  gap     time between one event arriving and the next. Holding a key makes
          the terminal repeat at a fixed cadence, so the spread of the gaps
          is delivery jitter. This is the one that exposes a queue: a loop
          that dispatches one key per redraw quantises gaps to a frame.
  hold    press to release for the same key, which needs kitty event types.
  echo    a DSR cursor query, timed until the reply comes back. The reply
          is written by whatever is emulating this terminal, so inside tmm
          it measures tmm's parse path -- the same lock a keypress needs.

What no program in this position can measure is the time from the key going
down to a byte arriving, because nothing in the byte says when it was
pressed. That needs a sender with a clock, which is tests/keylag.py.

The blast never blocks: stdout is nonblocking and a refused write is
counted, not waited on. Otherwise the tool would be reporting time it
spent stuck in write as though the key had been slow to arrive.
"""
import argparse
import fcntl
import os
import select
import signal
import statistics
import struct
import sys
import termios
import time
import tty

# Kitty keyboard protocol flags.
DISAMBIGUATE, EVENT_TYPES, ALTERNATES, ALL_ESCAPES, TEXT = 1, 2, 4, 8, 16
FLAG_NAMES = [(DISAMBIGUATE, 'disambiguate'), (EVENT_TYPES, 'events'),
              (ALTERNATES, 'alternates'), (ALL_ESCAPES, 'all-escapes'),
              (TEXT, 'text')]
# Cycled by F2. Release events need EVENT_TYPES; seeing a bare shift at all
# needs ALL_ESCAPES, which is what made U+E061 show up as a space in vi.
FLAG_SETS = [
    DISAMBIGUATE | EVENT_TYPES | ALTERNATES | ALL_ESCAPES | TEXT,
    DISAMBIGUATE | EVENT_TYPES | TEXT,
    DISAMBIGUATE,
    0,
]
EVENT_KIND = {1: 'press', 2: 'repeat', 3: 'release'}
MOD_BITS = [(1, 'shift'), (2, 'alt'), (4, 'ctrl'), (8, 'super'),
            (16, 'hyper'), (32, 'meta'), (64, 'caps'), (128, 'num')]

# Kitty's functional keys live in the private use area.
FUNCTIONAL = {
    57344: 'escape', 57345: 'enter', 57346: 'tab', 57347: 'backspace',
    57348: 'insert', 57349: 'delete', 57350: 'left', 57351: 'right',
    57352: 'up', 57353: 'down', 57354: 'page_up', 57355: 'page_down',
    57356: 'home', 57357: 'end', 57358: 'caps_lock', 57359: 'scroll_lock',
    57360: 'num_lock', 57361: 'print_screen', 57362: 'pause', 57363: 'menu',
    57376: 'f13', 57377: 'f14', 57378: 'f15', 57379: 'f16', 57380: 'f17',
    57381: 'f18', 57382: 'f19', 57383: 'f20', 57384: 'f21', 57385: 'f22',
    57386: 'f23', 57387: 'f24', 57399: 'kp_0', 57400: 'kp_1', 57401: 'kp_2',
    57402: 'kp_3', 57403: 'kp_4', 57404: 'kp_5', 57405: 'kp_6',
    57406: 'kp_7', 57407: 'kp_8', 57408: 'kp_9', 57409: 'kp_decimal',
    57410: 'kp_divide', 57411: 'kp_multiply', 57412: 'kp_subtract',
    57413: 'kp_add', 57414: 'kp_enter', 57415: 'kp_equal',
    57417: 'kp_left', 57418: 'kp_right', 57419: 'kp_up', 57420: 'kp_down',
    57441: 'left_shift', 57442: 'left_ctrl', 57443: 'left_alt',
    57444: 'left_super', 57447: 'right_shift', 57448: 'right_ctrl',
    57449: 'right_alt', 57450: 'right_super',
}
# The legacy forms, for comparison when the kitty flags are off.
CSI_FINAL = {'A': 'up', 'B': 'down', 'C': 'right', 'D': 'left', 'H': 'home',
             'F': 'end', 'P': 'f1', 'Q': 'f2', 'R': 'f3', 'S': 'f4',
             'E': 'kp_begin', 'Z': 'back_tab'}
CSI_TILDE = {1: 'home', 2: 'insert', 3: 'delete', 4: 'end', 5: 'page_up',
             6: 'page_down', 7: 'home', 8: 'end', 11: 'f1', 12: 'f2',
             13: 'f3', 14: 'f4', 15: 'f5', 17: 'f6', 18: 'f7', 19: 'f8',
             20: 'f9', 21: 'f10', 23: 'f11', 24: 'f12'}
C0 = {0: 'nul', 8: 'backspace', 9: 'tab', 10: 'line_feed', 13: 'enter',
      27: 'escape', 127: 'backspace'}


class Event:
    """One decoded key, with the bytes it came from kept for display."""

    def __init__(self, raw, at, name='?', kind='press', cp=None, mods=0,
                 protocol='legacy', text='', note=''):
        self.raw, self.at, self.name, self.kind = raw, at, name, kind
        self.cp, self.mods, self.protocol = cp, mods, protocol
        self.text, self.note = text, note
        self.gap = None

    def mod_text(self):
        held = [n for bit, n in MOD_BITS if self.mods & bit]
        return '+'.join(held) if held else '-'

    def english(self):
        """A description in words, which is the point of the tool."""
        parts = []
        if self.mods:
            parts.append(self.mod_text().replace('+', '-'))
        parts.append(self.name)
        words = ' '.join(parts)
        if self.kind != 'press':
            words = '%s (%s)' % (words, self.kind)
        return words


def key_name(cp, text):
    if cp is None:
        return '?'
    if cp in FUNCTIONAL:
        return FUNCTIONAL[cp]
    if cp in C0:
        return C0[cp]
    if cp < 32:
        return 'ctrl-%s' % chr(cp + 96)
    if 0xe000 <= cp <= 0xf8ff:
        return 'private-use U+%04X' % cp
    if cp == 32:
        return 'space'
    try:
        return chr(cp)
    except ValueError:
        return 'U+%04X' % cp


class Parser:
    """Incremental: a sequence may arrive split across reads."""

    def __init__(self):
        self.buf = b''

    def feed(self, data, at):
        self.buf += data
        out = []
        while self.buf:
            event, used = self.one(self.buf, at)
            if used == 0:
                break                      # incomplete, wait for more bytes
            self.buf = self.buf[used:]
            if event is not None:
                out.append(event)
        return out

    def one(self, b, at):
        if b[0] != 0x1b:
            return self.plain(b, at)
        if len(b) == 1:
            return None, 0
        if b[1] == ord('['):
            return self.csi(b, at)
        if b[1] == ord('O'):               # SS3, the old cursor-key form
            if len(b) < 3:
                return None, 0
            name = CSI_FINAL.get(chr(b[2]), 'ss3 %r' % chr(b[2]))
            return Event(b[:3], at, name=name, protocol='SS3'), 3
        if b[1] == 0x1b:
            return Event(b[:1], at, name='escape', cp=27), 1
        # ESC + byte is how a terminal without kitty reports alt.
        event, used = self.plain(b[1:], at)
        if used == 0:
            return None, 0
        event.raw, event.mods = b[:1 + used], event.mods | 2
        return event, 1 + used

    def plain(self, b, at):
        first = b[0]
        length = 1
        if first >= 0xf0:
            length = 4
        elif first >= 0xe0:
            length = 3
        elif first >= 0xc0:
            length = 2
        if len(b) < length:
            return None, 0
        raw = b[:length]
        try:
            char = raw.decode()
            cp = ord(char)
        except UnicodeDecodeError:
            return Event(raw, at, name='invalid utf-8'), length
        mods = 4 if first < 32 and first not in (9, 10, 13, 27) else 0
        text = char if cp >= 32 and cp != 127 else ''
        return Event(raw, at, name=key_name(cp, text), cp=cp, mods=mods,
                     protocol='raw byte', text=text), length

    def csi(self, b, at):
        i = 2
        while i < len(b) and (0x30 <= b[i] <= 0x3f):
            i += 1
        while i < len(b) and (0x20 <= b[i] <= 0x2f):
            i += 1
        if i >= len(b):
            return None, 0
        final = chr(b[i])
        body = b[2:i].decode(errors='replace')
        raw, used = b[:i + 1], i + 1

        if final == 'R' and ';' in body:
            return Event(raw, at, name='cursor position report',
                         kind='reply', protocol='DSR', note=body), used
        if final in 'Mm':
            return Event(raw, at, name='mouse', kind='mouse',
                         protocol='mouse', note=body), used

        groups = body.split(';')
        # Each group may carry sub-parameters after a colon.
        def sub(group, index, default=0):
            parts = group.split(':') if group else []
            if index < len(parts) and parts[index] != '':
                try:
                    return int(parts[index])
                except ValueError:
                    return default
            return default

        mods, kind = 0, 'press'
        if len(groups) > 1:
            raw_mods = sub(groups[1], 0, 1)
            mods = max(0, raw_mods - 1)
            kind = EVENT_KIND.get(sub(groups[1], 1, 1), 'press')
        text = ''
        if len(groups) > 2:
            try:
                text = ''.join(chr(int(p)) for p in groups[2].split(':') if p)
            except ValueError:
                text = ''

        if final == 'u':
            cp = sub(groups[0], 0, None) if groups and groups[0] else None
            shifted, base = sub(groups[0], 1, None), sub(groups[0], 2, None)
            note = ''
            if shifted:
                note = 'shifted=%s' % key_name(shifted, '')
            if base:
                note = (note + ' base=%s' % key_name(base, '')).strip()
            if text:
                note = (note + ' text=%r' % text).strip()
            return Event(raw, at, name=key_name(cp, text), kind=kind, cp=cp,
                         mods=mods, protocol='kitty CSI u', text=text,
                         note=note), used
        if final == '~':
            number = sub(groups[0], 0, 0) if groups and groups[0] else 0
            name = CSI_TILDE.get(number, 'csi %d~' % number)
            proto = 'kitty CSI ~' if (kind != 'press' or len(groups) > 2) else 'CSI ~'
            return Event(raw, at, name=name, kind=kind, mods=mods,
                         protocol=proto, text=text), used
        if final in CSI_FINAL:
            proto = 'kitty CSI' if kind != 'press' else 'CSI'
            return Event(raw, at, name=CSI_FINAL[final], kind=kind,
                         mods=mods, protocol=proto, text=text), used
        return Event(raw, at, name='CSI %s%s' % (body, final),
                     protocol='CSI', note='unrecognised'), used


class Scope:
    def __init__(self, args):
        self.args = args
        self.flags_index = 0
        self.flags = FLAG_SETS[0] if not args.no_kitty else 0
        self.blast = not args.no_blast
        self.parser = Parser()
        self.events = []
        self.gaps = []
        self.holds = []
        self.echoes = []
        self.pending_press = {}
        self.echo_sent = None
        self.echo_due = 0.0
        self.last_at = None
        self.dropped = 0
        self.written = 0
        self.frames = 0
        self.since = time.monotonic()
        self.rate = (0.0, 0.0)
        self.rows, self.cols = self.size()
        self.log = open(args.log, 'a', buffering=1) if args.log else None
        self.quit = False
        self.panel_dirty = True
        self.last_interrupt = None
        self.panel_note = ''
        self.out = bytearray()
        self.prev_at = None

    def size(self):
        try:
            packed = fcntl.ioctl(1, termios.TIOCGWINSZ, b'\0' * 8)
            rows, cols = struct.unpack('HHHH', packed)[:2]
            return max(rows, 12), max(cols, 40)
        except OSError:
            return 24, 80

    # ---- terminal setup ----------------------------------------------
    def __enter__(self):
        self.saved = termios.tcgetattr(0)
        tty.setraw(0)
        os.set_blocking(1, False)
        self.emit('\x1b[?1049h\x1b[?25l')        # alt screen, hide cursor
        self.push_flags()
        signal.signal(signal.SIGWINCH, self.on_winch)
        return self

    def __exit__(self, *_):
        if self.flags:
            self.emit('\x1b[<u')
        self.emit('\x1b[?25h\x1b[?1049l')
        os.set_blocking(1, True)
        termios.tcsetattr(0, termios.TCSADRAIN, self.saved)
        if self.log:
            self.log.close()

    def on_winch(self, *_):
        self.rows, self.cols = self.size()
        self.panel_dirty = True

    def push_flags(self):
        if self.flags:
            self.emit('\x1b[>%du' % self.flags)
        else:
            self.emit('\x1b[<u')

    def emit(self, text):
        """Queue output. Nothing is ever written in part and abandoned.

        stdout is nonblocking, so a write may accept only some of what it
        was given. Dropping the rest puts a truncated escape sequence on the
        wire, which is why the blast used to leave `26l` and stray colour
        across the screen. So everything queues here and `flush` writes what
        the terminal will take, keeping the remainder for next time. Load is
        shed by declining to queue a new frame while the last one is still
        going out, never by abandoning one mid-sequence.
        """
        self.out += text.encode() if isinstance(text, str) else text

    def flush(self):
        """Write what the terminal will accept. True when the queue is empty."""
        while self.out:
            try:
                written = os.write(1, self.out)
            except BlockingIOError:
                return False
            except OSError:
                self.quit = True
                return False
            if written == 0:
                return False
            self.written += written
            del self.out[:written]
        return True

    # ---- the blast ---------------------------------------------------
    def blast_rows(self):
        height = self.rows - self.panel_height()
        if height <= 0:
            return
        out = ['\x1b[H']
        for y in range(height):
            colour = 31 + ((y + self.frames) % 6)
            glyph = '█▓▒░'[(y + self.frames) % 4]
            out.append('\x1b[%d;1H\x1b[%dm%s\x1b[0m' %
                       (y + 1, colour, glyph * (self.cols - 1)))
        self.emit(''.join(out))

    # ---- the panel ---------------------------------------------------
    def panel_height(self):
        return min(self.rows - 2, 4 + self.args.lines)

    def stats(self, values):
        if not values:
            return 'none yet'
        ordered = sorted(values)
        p90 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.9))]
        return 'min %5.1f  med %5.1f  p90 %5.1f  max %6.1f' % (
            ordered[0], statistics.median(ordered), p90, ordered[-1])

    def flag_text(self):
        if not self.flags:
            return 'off (legacy encoding)'
        held = [name for bit, name in FLAG_NAMES if self.flags & bit]
        return '%d (%s)' % (self.flags, '|'.join(held))

    def draw_panel(self):
        top = self.rows - self.panel_height() + 1
        bytes_s, fps = self.rate
        lines = [
            '\x1b[7m keyscope   blast %s %6.2f MB/s %5.1f fps   '
            'kitty flags=%s \x1b[0m' % (
                'on ' if self.blast else 'off',
                bytes_s / 1e6, fps, self.flag_text()),
            ' events %-5d  gap ms: %s' % (len(self.events), self.stats(self.gaps)),
            ' hold ms: %-44s  echo ms: %s' % (
                self.stats(self.holds).replace('  ', ' '),
                self.stats(self.echoes).replace('  ', ' ')),
            ' \x1b[2mF1 blast   F2 kitty flags   F3 reset   F10 quit%s'
            '\x1b[0m%s' % (
                '   log: %s' % self.args.log if self.args.log else '',
                '  \x1b[33m%s\x1b[0m' % self.panel_note if self.panel_note else ''),
        ]
        out = []
        for i, line in enumerate(lines):
            out.append('\x1b[%d;1H\x1b[K%s' % (top + i, line[:self.cols + 20]))
        shown = self.events[-self.args.lines:]
        for i in range(self.args.lines):
            row = top + len(lines) + i
            if row > self.rows:
                break
            out.append('\x1b[%d;1H\x1b[K' % row)
            if i < len(shown):
                out.append(self.format_event(shown[i])[:self.cols + 40])
        self.emit(''.join(out))

    def format_event(self, e):
        gap = '   --  ' if e.gap is None else '%+7.1f' % e.gap
        colour = {'press': 32, 'repeat': 33, 'release': 36,
                  'reply': 90, 'mouse': 35}.get(e.kind, 37)
        hexed = e.raw.hex()
        if len(hexed) > 28:
            hexed = hexed[:26] + '..'
        return ('\x1b[2m%sms\x1b[0m \x1b[%dm%-8s\x1b[0m %-22s cp=%-6s '
                'mods=%-12s \x1b[2m%-14s %s\x1b[0m %s' % (
                    gap, colour, e.kind, e.english()[:22],
                    e.cp if e.cp is not None else '-',
                    e.mod_text()[:12], e.protocol, hexed, e.note[:18]))

    # ---- event handling ----------------------------------------------
    def record(self, e):
        # Gaps are counted only between keys: a DSR reply landing between
        # two keystrokes is not a gap in anybody's typing.
        if e.kind in ('press', 'repeat', 'release'):
            if self.last_at is not None:
                self.gaps.append((e.at - self.last_at) * 1000.0)
            self.last_at = e.at
        if e.kind in ('press', 'repeat'):
            self.pending_press[e.cp] = e.at
        elif e.kind == 'release' and e.cp in self.pending_press:
            self.holds.append((e.at - self.pending_press.pop(e.cp)) * 1000.0)
        if e.kind == 'reply' and self.echo_sent is not None:
            self.echoes.append((e.at - self.echo_sent) * 1000.0)
            self.echo_sent = None
        if e.kind == 'reply' and not self.args.show_replies:
            self.panel_dirty = True
            return
        # The displayed gap runs between listed events, so it reads as a
        # timeline of the list. Updated here, after the events that are not
        # listed have been dropped, or an unlisted reply would silently
        # become the thing the next key is timed against.
        if self.prev_at is not None:
            e.gap = (e.at - self.prev_at) * 1000.0
        self.prev_at = e.at
        self.events.append(e)
        if len(self.events) > 4000:
            del self.events[:2000]
        if self.log:
            self.log.write('%.6f gap=%s %-8s %-24s cp=%s mods=%s %s %s %s\n' % (
                e.at, 'none' if e.gap is None else '%.3f' % e.gap, e.kind,
                e.english(), e.cp, e.mod_text(), e.protocol, e.raw.hex(),
                e.note))
        self.panel_dirty = True
        self.control(e)

    def control(self, e):
        if e.kind not in ('press', 'repeat'):
            return
        interrupt = e.name == 'ctrl-c' or (e.name == 'c' and 'ctrl' in e.mod_text())
        if e.name == 'f10':
            self.quit = True
        elif interrupt:
            # Twice in a row, so a single one stays inspectable.
            if self.last_interrupt and e.at - self.last_interrupt < 1.5:
                self.quit = True
            self.last_interrupt = e.at
            self.panel_note = 'ctrl-c again within 1.5s to quit'
        elif e.name == 'f1':
            self.blast = not self.blast
            self.emit('\x1b[2J')
        elif e.name == 'f2':
            self.flags_index = (self.flags_index + 1) % len(FLAG_SETS)
            self.flags = FLAG_SETS[self.flags_index]
            self.push_flags()
        elif e.name == 'f3':
            self.gaps.clear()
            self.holds.clear()
            self.echoes.clear()
            self.events.clear()
            self.last_at = None

    # ---- the loop ----------------------------------------------------
    def run(self):
        last_panel = 0.0
        frame_bytes, frame_start = 0, time.monotonic()
        while not self.quit:
            # Block until there is a key to read or room to write, so the
            # tool costs nothing while the terminal is busy. Spinning here
            # made it a CPU rival of the thing it was measuring, and the
            # frame counter reported 56000 fps of mostly refused writes.
            writable = [1] if self.out else []
            timeout = 0.05 if (self.out or not self.blast) else 0.002
            ready, _, _ = select.select([0], writable, [], timeout)
            if ready:
                at = time.monotonic()
                try:
                    data = os.read(0, 4096)
                except OSError:
                    break
                if not data:
                    break
                for event in self.parser.feed(data, at):
                    self.record(event)

            before = self.written
            self.flush()
            frame_bytes += self.written - before
            now = time.monotonic()

            if self.args.echo and self.echo_sent is None and now >= self.echo_due:
                self.echo_sent = now
                self.echo_due = now + 0.2
                self.emit('\x1b[6n')
            elif self.echo_sent is not None and now - self.echo_sent > 2.0:
                self.echo_sent = None      # no emulator answered; stop waiting

            # Nothing new is queued until the last thing is fully out, so
            # the blast paces itself and the frame count is a real one. The
            # panel goes first when it is due: it is the readout, and gating
            # it on a quiet queue meant a continuous blast starved it
            # completely -- the instrument ran with a blank display.
            if not self.out:
                if self.panel_dirty and now - last_panel > 0.05:
                    self.draw_panel()
                    last_panel, self.panel_dirty = now, False
                elif self.blast:
                    self.blast_rows()
                    self.frames += 1

            if now - frame_start >= 0.5:
                span = now - frame_start
                self.rate = (frame_bytes / span, self.frames / span)
                frame_bytes, self.frames, frame_start = 0, 0, now
                self.panel_dirty = True


SELF_TEST = [
    (b'\x1b[97;1u', 'press', 'a', 97, '-', 'kitty CSI u'),
    (b'\x1b[97;1:3u', 'release', 'a', 97, '-', 'kitty CSI u'),
    (b'\x1b[97;1:2u', 'repeat', 'a', 97, '-', 'kitty CSI u'),
    (b'\x1b[57441;1u', 'press', 'left_shift', 57441, '-', 'kitty CSI u'),
    (b'\x1b[57441;1:3u', 'release', 'left_shift', 57441, '-', 'kitty CSI u'),
    (b'\x1b[99;5u', 'press', 'c', 99, 'ctrl', 'kitty CSI u'),
    (b'\x1b[97;4u', 'press', 'a', 97, 'shift+alt', 'kitty CSI u'),
    (b'\x1b[1;2A', 'press', 'up', None, 'shift', 'CSI'),
    (b'\x1b[3~', 'press', 'delete', None, '-', 'CSI ~'),
    (b'\x1b[21~', 'press', 'f10', None, '-', 'CSI ~'),
    (b'\x1bOP', 'press', 'f1', None, '-', 'SS3'),
    (b'q', 'press', 'q', 113, '-', 'raw byte'),
    (b'\x03', 'press', 'ctrl-c', 3, 'ctrl', 'raw byte'),
    (b'\xc3\xa9', 'press', '\u00e9', 233, '-', 'raw byte'),
    (b'\x1b[6;1R', 'reply', 'cursor position report', None, '-', 'DSR'),
]


def self_test():
    """Check the decoder against known sequences. No terminal required."""
    failures = []
    for raw, kind, name, cp, mods, protocol in SELF_TEST:
        events = Parser().feed(raw, 0.0)
        if len(events) != 1:
            failures.append('%r decoded to %d events' % (raw, len(events)))
            continue
        e = events[0]
        for field, want, got in (('kind', kind, e.kind), ('name', name, e.name),
                                 ('cp', cp, e.cp), ('mods', mods, e.mod_text()),
                                 ('protocol', protocol, e.protocol)):
            if want != got:
                failures.append('%r %s: want %r, got %r' % (raw, field, want, got))
    # A sequence split across reads has to survive the split.
    parser = Parser()
    assert parser.feed(b'\x1b[97', 0.0) == []
    split = parser.feed(b';1:3u', 0.0)
    if len(split) != 1 or split[0].kind != 'release':
        failures.append('a sequence split across reads was not reassembled')
    # Associated text travels in the third parameter group.
    with_text = Parser().feed(b'\x1b[200;1;104:105u', 0.0)
    if not with_text or with_text[0].text != 'hi':
        failures.append('associated text was not decoded')
    for f in failures:
        print('FAIL', f)
    print('keyscope self-test: %d sequences, %s'
          % (len(SELF_TEST), 'PASS' if not failures else 'FAIL'))
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--no-blast', action='store_true',
                    help='start with the screen blast off')
    ap.add_argument('--no-kitty', action='store_true',
                    help='start with the kitty keyboard protocol off')
    ap.add_argument('--no-echo', dest='echo', action='store_false',
                    help='do not send DSR cursor queries')
    ap.add_argument('--self-test', action='store_true',
                    help='check the decoder against known sequences and exit')
    ap.add_argument('--show-replies', action='store_true',
                    help='list the DSR replies too, not just their timing')
    ap.add_argument('--lines', type=int, default=14,
                    help='how many recent events to show (default 14)')
    ap.add_argument('--log', default='/tmp/keyscope-%d.log' % os.getpid(),
                    help='where to log every event, or empty for no log')
    args = ap.parse_args()
    if args.self_test:
        raise SystemExit(self_test())
    if not sys.stdin.isatty():
        raise SystemExit('keyscope needs a terminal on stdin')
    with Scope(args) as scope:
        scope.run()
    print('keyscope: %d events logged to %s' % (len(scope.events), args.log)
          if args.log else 'keyscope: %d events' % len(scope.events))


if __name__ == '__main__':
    main()
