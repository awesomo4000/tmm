# vendor/

## libghostty-vt-source.tar.gz

libghostty-vt, vendored as the release tarball rather than depended on from git.
`build.zig.zon` points `ghostty_vt` at this file by relative path; Zig unpacks it
into the package cache at build time, so only the 4 MB archive lives in the
repository.

### What this copy is

| | |
| --- | --- |
| Unpacks as | `libghostty-vt-1.3.2-main+e3ebb1d` |
| ghostty commit | `e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110` (main, 2026-10-16) |
| Source | `libghostty-vt-source.tar.gz` asset of the `tip` release |
| Asset built | 2026-10-16T18:56:27Z |
| Archive | 4.1 MB; 22 MB unpacked |
| Zig | requires 0.16.0 |

`src/vt.zig` asserts the **OSC 7501 program status protocol** parser
(`src/terminal/osc/parsers/program_status.zig`) is present, as a capability
rather than a version, so a future pin bump that loses it fails loudly rather
than letting the status code fall back to screen scraping silently. That
parser landed in PR #14560 on 2026-10-06 and is why this file stopped
tracking an older commit.

### What this bump brought in

158 commits, of which the ones that change what tmm can parse or emit:

- **OSC 7501 revision 0.4** (#14630). Same `state` and `kind` vocabulary, so
  the capability test still passes, but the support handshake changed: a
  terminal now answers a query with a distinct `query_reply` rather than
  echoing the query back. Anything written against the older revision would
  have had to be redone, which is the argument for bumping this before
  building on the protocol rather than after.
- **OSC 3008 Hierarchical Context Signalling** (#14700), a separate protocol
  from the UAPI group: https://uapi-group.org/specifications/specs/osc_context/
  Contexts carry an id and metadata and form a stack, so a shell can tell the
  terminal what it is running and what that is running in turn. That is the
  process hierarchy tmm currently infers by walking PID ancestry in
  `model.processAgentInfo`, offered explicitly instead. Not in the previous
  pin at all.
- `CSI 8 t` window resize requests are now reported to embedders (#14610),
  where libghostty-vt previously parsed and dropped them.
- `DECSTR` soft reset (#14538) and `DECXCPR` extended cursor position.
- Grapheme data is preserved when a wrapped line widens, and re-attached in
  one allocation. tmm leans on grapheme handling: `tests/split_shell.py` has
  a box-drawing regression for it, which still passes.

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
