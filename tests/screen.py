#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A minimal screen model for asserting on what a tmm test run displays.

Stripping escape sequences out of the captured bytes is not good enough.
libvaxis diffs against the previous frame and emits only the cells that
changed, each preceded by a cursor move, so a line that reads "F12 sidebar"
on screen arrives as "F12", "sid", "bar" with the unchanged cells missing.
Any assertion on rendered text has to replay the cursor.

This handles the subset libvaxis emits: absolute and relative cursor moves,
erases, text, the foreground and background colour of each cell, and the
colour of its underline when it has one. Other styles are discarded; this
answers "what does it say, and in which colours", not "what does it look
like".

A colour is ('index', n) for a palette entry, ('rgb', r, g, b) for a direct
one, or None for the default. Per cell is the only way to ask, because tmm
recolours text one cell at a time, so the bytes of a word are interleaved
with colour changes and a raw search for the word finds nothing.
"""
import re

PARAMS = re.compile(rb'^([0-9;:?<>=!]*)([ -/]*)([@-~])')
# A CSI with no final byte yet: what PARAMS would match, stopped short.
INCOMPLETE = re.compile(rb'[0-9;:?<>=!]*[ -/]*')


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[' '] * cols for _ in range(rows)]
        self.colours = [[None] * cols for _ in range(rows)]
        self.backgrounds = [[None] * cols for _ in range(rows)]
        self.underlines = [[None] * cols for _ in range(rows)]
        self.row = self.col = 0
        self.fg = self.bg = None
        self.underlined = False
        self.ul = None
        # The tail of the last feed when it ended inside an escape sequence or
        # a UTF-8 character. Output arrives in whatever chunks the reads
        # return, and a sequence split across two of them otherwise lands on
        # screen as text.
        self.pending = b''

    def colour(self, row, col):
        return self.colours[row][col]

    def background(self, row, col):
        return self.backgrounds[row][col]

    def underline(self, row, col):
        """The underline colour, 'default' for one without a colour, or None."""
        return self.underlines[row][col]

    def line(self, row):
        return ''.join(self.grid[row]).rstrip()

    def lines(self):
        return [self.line(r) for r in range(self.rows)]

    def text(self):
        return '\n'.join(self.lines())

    def column(self, col):
        """One vertical slice, which is how a divider is checked."""
        return ''.join(self.grid[r][col] for r in range(self.rows))

    def region(self, first_col):
        """The lines right of `first_col`, as the terminal region occupies."""
        return [''.join(self.grid[r][first_col:]).rstrip() for r in range(self.rows)]

    def _put(self, ch):
        if self.col >= self.cols:
            self.col = 0
            self.row += 1
        if 0 <= self.row < self.rows and 0 <= self.col < self.cols:
            self.grid[self.row][self.col] = ch
            self.colours[self.row][self.col] = self.fg
            self.backgrounds[self.row][self.col] = self.bg
            self.underlines[self.row][self.col] = (self.ul or 'default') if self.underlined else None
        self.col += 1

    def feed(self, data: bytes):
        data = self.pending + data
        self.pending = b''
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            if b == 0x1b:
                used = self._escape(data[i:])
                if used is None:
                    self.pending = data[i:]
                    return self
                i += used
                continue
            i += 1
            if b == 0x0d:
                self.col = 0
            elif b == 0x0a:
                self.row += 1
            elif b == 0x08:
                self.col = max(0, self.col - 1)
            elif b == 0x09:
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif b == 0x07:
                pass
            elif b < 0x20:
                pass
            elif b < 0x80:
                self._put(chr(b))
            else:
                # One UTF-8 sequence is one cell for everything tmm draws.
                width = 2 if b < 0xe0 else 3 if b < 0xf0 else 4
                if i - 1 + width > n:
                    self.pending = data[i - 1:]
                    return self
                self._put(data[i - 1:i - 1 + width].decode('utf-8', 'replace'))
                i += width - 1
        return self

    def _escape(self, data: bytes):
        """Bytes used by the sequence at the start, or None if it is cut off."""
        if len(data) < 2:
            return None
        kind = data[1]
        if kind == ord('['):
            match = PARAMS.match(data[2:])
            if not match:
                return None if INCOMPLETE.fullmatch(data[2:]) else 2
            self._csi(match.group(1), match.group(3))
            return 2 + match.end()
        if kind in (ord(']'), ord('_'), ord('P'), ord('^'), ord('X')):
            # String sequences, terminated by BEL or ST.
            end = data.find(b'\x07', 2)
            st = data.find(b'\x1b\\', 2)
            if st != -1 and (end == -1 or st < end):
                return st + 2
            return end + 1 if end != -1 else None
        return 2

    def _sgr(self, params: bytes):
        # A colour in colon form is one parameter whose parts may include an
        # empty colour-space id, as in 58:2::r:g:b. Rewrite it in the
        # semicolon form, dropping that id, so the parts line up below.
        groups = []
        for group in (params or b'0').split(b';'):
            parts = group.split(b':')
            if len(parts) == 6 and parts[1] == b'2':
                parts = parts[:2] + parts[3:]
            groups.extend(parts)
        args = [int(p) if p.isdigit() else 0 for p in groups]
        i = 0
        while i < len(args):
            p = args[i]
            if p == 0:
                self.fg = self.bg = self.ul = None
                self.underlined = False
            elif p == 4:
                self.underlined = True
            elif p == 24:
                self.underlined = False
            elif p == 59:
                self.ul = None
            elif p == 39:
                self.fg = None
            elif p == 49:
                self.bg = None
            elif 30 <= p <= 37:
                self.fg = ('index', p - 30)
            elif 40 <= p <= 47:
                self.bg = ('index', p - 40)
            elif 90 <= p <= 97:
                self.fg = ('index', p - 82)
            elif 100 <= p <= 107:
                self.bg = ('index', p - 92)
            elif p in (38, 48, 58) and i + 1 < len(args):
                colour = None
                if args[i + 1] == 5 and i + 2 < len(args):
                    colour = ('index', args[i + 2])
                    i += 2
                elif args[i + 1] == 2 and i + 4 < len(args):
                    colour = ('rgb', *args[i + 2:i + 5])
                    i += 4
                if colour is not None:
                    if p == 38:
                        self.fg = colour
                    elif p == 48:
                        self.bg = colour
                    else:
                        self.ul = colour
            i += 1

    def _csi(self, params: bytes, final: bytes):
        # One byte, compared as an int below. Kept as bytes, every
        # `final == ord(...)` was false, so relative moves and erases were
        # silently ignored and only absolute moves worked.
        final = final[0]
        if final == ord('m') and not params.startswith(b'?'):
            self._sgr(params)
            return
        if params.startswith(b'?') or b':' in params:
            return
        text = params.decode('ascii', 'replace')
        args = [int(p) if p.isdigit() else 0 for p in text.split(';')] if text else []

        def arg(index, default=1):
            return args[index] if index < len(args) and args[index] else default

        if final in b'Hf':
            self.row, self.col = arg(0) - 1, arg(1) - 1
        elif final == ord('A'):
            self.row = max(0, self.row - arg(0))
        elif final == ord('B'):
            self.row += arg(0)
        elif final == ord('C'):
            self.col += arg(0)
        elif final == ord('D'):
            self.col = max(0, self.col - arg(0))
        elif final == ord('G'):
            self.col = arg(0) - 1
        elif final == ord('d'):
            self.row = arg(0) - 1
        elif final == ord('J'):
            mode = arg(0, 0)
            start = 0 if mode == 2 else self.row
            if mode != 2 and 0 <= self.row < self.rows:
                for c in range(self.col, self.cols):
                    self.grid[self.row][c] = ' '
                    self.colours[self.row][c] = None
                    self.backgrounds[self.row][c] = None
                    self.underlines[self.row][c] = None
                start = self.row + 1
            for r in range(max(0, start), self.rows):
                self.grid[r] = [' '] * self.cols
                self.colours[r] = [None] * self.cols
                self.backgrounds[r] = [None] * self.cols
                self.underlines[r] = [None] * self.cols
        elif final == ord('K'):
            if 0 <= self.row < self.rows:
                mode = arg(0, 0)
                first = 0 if mode in (1, 2) else self.col
                last = self.cols if mode in (0, 2) else self.col + 1
                for c in range(max(0, first), min(self.cols, last)):
                    self.grid[self.row][c] = ' '
                    self.colours[self.row][c] = None
                    self.backgrounds[self.row][c] = None
                    self.underlines[self.row][c] = None
