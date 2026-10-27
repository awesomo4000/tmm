#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the end-to-end tests at once, and report them in order.

Each test owns its tmux sockets and directories under /tmp, so nothing is
shared and they can run side by side; what they spend is mostly waiting on
tmm and tmux, not CPU. Run one after another, the suite took as long as the
sum of its tests; together it takes about as long as the slowest.

Output is held per test and printed whole when it finishes, so a failure
reads as one block rather than interleaved with its neighbours. Exits
nonzero if any test failed.

    python3 tests/run.py tests/a.py tests/b.py ...
"""
import subprocess
import sys
import tempfile
import time


def main(paths):
    started = time.monotonic()
    # Output to files, not pipes: a pipe nobody reads until the end blocks a
    # test that writes more than its buffer, and the suite hangs.
    running = []
    for path in paths:
        log = tempfile.TemporaryFile()
        proc = subprocess.Popen([sys.executable, path], stdout=log, stderr=subprocess.STDOUT)
        running.append({'path': path, 'proc': proc, 'log': log, 'took': None})
    while any(r['took'] is None for r in running):
        for r in running:
            if r['took'] is None and r['proc'].poll() is not None:
                r['took'] = time.monotonic() - started
        time.sleep(0.05)
    failed = []
    for r in running:
        ok = r['proc'].returncode == 0
        print('%s %-34s %5.1fs' % ('ok  ' if ok else 'FAIL', r['path'], r['took']))
        if not ok:
            failed.append(r['path'])
            r['log'].seek(0)
            sys.stdout.write(r['log'].read().decode(errors='replace'))
        r['log'].close()
    print('%d tests, %d failed, %.1fs' % (len(paths), len(failed), time.monotonic() - started))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
