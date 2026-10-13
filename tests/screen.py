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
erases, and text. Styles are discarded; this answers "what does it say", not
"what does it look like".
"""
import re

PARAMS = re.compile(rb'^([0-9;:?<>=!]*)([ -/]*)([@-~])')


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[' '] * cols for _ in range(rows)]
        self.row = self.col = 0

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
        self.col += 1

    def feed(self, data: bytes):
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            if b == 0x1b:
                i += self._escape(data[i:])
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
                self._put(data[i - 1:i - 1 + width].decode('utf-8', 'replace'))
                i += width - 1
        return self

    def _escape(self, data: bytes) -> int:
        if len(data) < 2:
            return len(data)
        kind = data[1]
        if kind == ord('['):
            match = PARAMS.match(data[2:])
            if not match:
                return 2
            self._csi(match.group(1), match.group(3))
            return 2 + match.end()
        if kind in (ord(']'), ord('_'), ord('P'), ord('^'), ord('X')):
            # String sequences, terminated by BEL or ST.
            end = data.find(b'\x07', 2)
            st = data.find(b'\x1b\\', 2)
            if st != -1 and (end == -1 or st < end):
                return st + 2
            return end + 1 if end != -1 else len(data)
        return 2

    def _csi(self, params: bytes, final: bytes):
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
                start = self.row + 1
            for r in range(max(0, start), self.rows):
                self.grid[r] = [' '] * self.cols
        elif final == ord('K'):
            if 0 <= self.row < self.rows:
                mode = arg(0, 0)
                first = 0 if mode in (1, 2) else self.col
                last = self.cols if mode in (0, 2) else self.col + 1
                for c in range(max(0, first), min(self.cols, last)):
                    self.grid[self.row][c] = ' '
