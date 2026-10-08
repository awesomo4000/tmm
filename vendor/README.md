# vendor/

## libghostty-vt-source.tar.gz

libghostty-vt, vendored as the release tarball rather than depended on from git.
`build.zig.zon` points `ghostty_vt` at this file by relative path; Zig unpacks it
into the package cache at build time, so only the 4 MB archive lives in the
repository.

### What this copy is

| | |
| --- | --- |
| Unpacks as | `libghostty-vt-1.3.2-main+8f0dd37` |
| ghostty commit | `8f0dd3709050b1026f6324368805033197d8b4a5` (main, 2026-10-08) |
| Source | `libghostty-vt-source.tar.gz` asset of the `tip` release |
| Asset built | 2026-10-08T07:20:41Z |
| Archive | 4.0 MB; 22 MB unpacked |
| Zig | requires 0.16.0 |

Chosen because this is the first build we used that contains the **OSC 7501
program status protocol** parser (`src/terminal/osc/parsers/program_status.zig`),
which landed in libghostty-vt in PR #14560 on 2026-10-06. The previous pin here
(`83edd491`, Oct 2) predated it and had no such parser. `src/vt.zig` has a test
asserting that parser is present, so losing it in a future update fails loudly.

### Why vendored rather than fetched

The only published source of this tarball is the `tip` release, a rolling
pre-release whose assets are replaced on every nightly build — the asset above
was rebuilt minutes before it was downloaded. Zig pins dependencies by content
hash, so pointing `build.zig.zon` at that URL means the build breaks outright
the next time tip rolls, on a schedule nobody here controls. No versioned
ghostty release carries this asset.

The git dependency it replaces was reproducible but fetched the whole ghostty
repository: 107 MB unpacked, of which the tests, images, macOS app and
translations are never compiled.

### Updating

1. Download the current asset:
   `gh release download tip --repo ghostty-org/ghostty --pattern "libghostty-vt-source.tar.gz"`
2. Check which commit it is: the archive's top-level directory is
   `libghostty-vt-<version>-main+<short sha>`.
3. Replace this file, then re-record the hash:
   `zig fetch --save=ghostty_vt vendor/libghostty-vt-source.tar.gz`
4. `zig build test` — the OSC 7501 and kitty-graphics capability tests in
   `src/vt.zig` must still pass.
5. Update the table above with the new commit and build date.

ghostty builds this archive itself with `zig build dist`, so a fork can publish
it on a versioned release and be depended on by URL instead, which would be
preferable to vendoring if one exists.
