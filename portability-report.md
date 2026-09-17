# Portability report

Tested on 09/10/2026 with Zig **0.16.0**, from a macOS ARM64 host.
Source commit: `9fda3b80a05a920f571f36b6502fe098011a9b5a`.
The working tree was clean before the initial matrix below. No source, build configuration, or dependency changes were made for that matrix. A subsequent Linux UID change and its results are recorded at the end.

These are cross-compilation and linking results only. No target binaries or target tests were executed, so a passing build does not establish working terminal input, tmux integration, process discovery, or agent status on that OS.

## Results

| Target | Result | Executable bytes | Details |
| --- | --- | ---: | --- |
| `aarch64-linux` | FAIL | — | Missing explicit libc dependency for `getuid`. |
| `x86_64-linux` | FAIL | — | Missing explicit libc dependency for `getuid`. |
| `aarch64-windows` | FAIL | — | libc, argument iterator, and environment API errors. |
| `x86_64-windows` | FAIL | — | libc, argument iterator, and environment API errors. |
| `aarch64-freebsd` | PASS | 470,312 | ELF architecture and OS checked with `file`. |
| `x86_64-freebsd` | PASS | 495,560 | ELF architecture and OS checked with `file`. |
| `aarch64-netbsd` | PASS | 503,488 | ELF architecture and OS checked with `file`. |
| `x86_64-netbsd` | PASS | 528,504 | ELF architecture and OS checked with `file`. |
| `aarch64-openbsd` | PASS | 739,424 | ELF architecture and OS checked with `file`. |
| `x86_64-openbsd` | PASS | 764,640 | ELF architecture and OS checked with `file`. |

Six of ten targets compiled and linked. All successful binaries are dynamically linked and stripped. The target names use Zig's default ABI and OS version; no explicit GNU/musl or OS-version variants were tested. `file` identifies the FreeBSD outputs as FreeBSD 14.0 and the NetBSD outputs as NetBSD 10.1.

## Reproduction

Run from the repository root, replacing `TARGET` with a target from the table:

```sh
mkdir -p /tmp/tmm-portability-20260910/tmp
TMPDIR=/tmp/tmm-portability-20260910/tmp \
ZIG_GLOBAL_CACHE_DIR=/tmp/tmm-zig-cache \
NO_COLOR=1 \
zig build -Doptimize=ReleaseSmall -Dtarget=TARGET \
  --prefix /tmp/tmm-portability-20260910/TARGET -j2
```

The builds used the existing dependency cache and the repository's pinned dependencies:

- libtmux commit `c63d5aa24d95c8bf757f8ad0b79f81da98275dbf`.
- libvaxis commit `f37c42a3b324131c131d066767968e1f5b976453`.

Local full build logs, per-target JSON results, and successful executables are in `/tmp/tmm-portability-20260910/`. These temporary artifacts are not included in the repository. The diagnostics below retain the observed failures without machine-specific absolute paths.

## Linux failures

Both architectures report the same error:

```text
std/c.zig:10782:12: error: dependency on libc must be explicitly specified in the build command
pub extern "c" fn getuid() uid_t;
referenced by:
    discover: src/sidebar.zig:96:111
    main: src/main.zig:110:29
```

This points to tmm's server discovery call to `std.c.getuid()`. No linking changes were attempted, so further errors after this blocker remain unknown.

## Windows failures

Both architectures report the same three errors:

```text
std/c.zig:10782:12: error: dependency on libc must be explicitly specified in the build command
pub extern "c" fn getuid() uid_t;
referenced by:
    discover: src/sidebar.zig:96:111
    main: src/main.zig:110:29

std/process/Args.zig:39:36: error: In Windows, use initAllocator instead.

std/process/Environ.zig:608:23: error: no field or member function named 'view' in 'process.Environ.GlobalBlock'
    for (environ.block.view().slice) |entry| {
```

tmm uses `init.minimal.args.iterate()` at `src/main.zig:59`. The environment error above is reported inside Zig's standard library; the default diagnostic did not include its caller chain.

The pinned libvaxis source selects `WindowsTty` for Windows in `src/tty.zig` and includes its implementation. Therefore this result does not establish that libvaxis lacks Windows support. It establishes that this version of tmm does not compile for the tested Windows targets. No standalone libvaxis Windows build was tested.

## Build environment retry

The first FreeBSD and NetBSD attempts failed while compiling libc startup objects because Clang could not create temporary files:

```text
zig: error: unable to make temporary file: Operation not permitted
```

Those four targets were rerun with `TMPDIR` set to the writable directory shown above. All four then passed without code changes. Their initial logs are preserved locally as `TARGET.initial.log`; the table records the final results. Linux, Windows, and OpenBSD results came from the initial attempts, which did not encounter this temporary-file error.

## Linux UID follow-up, 09/10/2026

Changed `src/sidebar.zig` from `std.c.getuid()` to `std.posix.system.getuid()`. In Zig 0.16.0, the POSIX system backend selects `std.os.linux` on Linux when libc is not linked. Its `getuid()` implementation invokes the kernel syscall directly. No libc linkage or dependency changes were added. macOS and BSD retain their existing system-library backend; this does not remove their system-library dependencies.

| Check after the change | Result |
| --- | --- |
| `aarch64-linux`, ReleaseSmall | PASS; `file` confirms a statically linked ARM64 ELF executable |
| `x86_64-linux`, ReleaseSmall | PASS; `file` confirms a statically linked x86-64 ELF executable |
| Native macOS ARM64, ReleaseSmall | PASS |
| Native `zig build test` | PASS |

The follow-up builds used the same cache and temporary directory, with output prefixes and logs named `uid-TARGET` under `/tmp/tmm-portability-20260910/`. Linux executables were not run. Windows and BSD were not rebuilt for this follow-up.

Further inspection of the pinned libvaxis confirms a Windows console backend, including console mode setup/restoration, Unicode keyboard input, mouse events, and window sizing in `src/tty.zig`. `src/Loop.zig` selects a Windows event loop using `WindowsTty.nextEvent()`. This confirms Windows-specific implementation exists, not that tmm currently builds or runs on Windows. The Windows blockers from the initial matrix remain unaddressed.

## MSYS2 tmux runtime check, 09/10/2026

Connected over SSH to Windows host `winny`. Found an existing MSYS2 installation at `C:\msys64`, with `pacman` and `msys2-runtime 3.6.9-2`. Installed `tmux 3.6.a-1` and its required `libevent 2.1.12-4` package using `pacman -S --needed --noconfirm tmux`. `tmux -V` reports `tmux 3.6a`; the executable is `C:\msys64\usr\bin\tmux.exe`.

Verified with disposable tmux servers using unique socket names and an empty configuration:

- Detached server/session startup succeeded.
- Sending a command into a pane and capturing its output succeeded.
- Splitting a window created two panes with MSYS2 `/dev/pty*` terminal paths.
- An explicitly launched `/usr/bin/bash --noprofile --norc` pane ran commands successfully, reporting `MSYS_NT-10.0-26200` and Bash `5.3.9(1)-release`.
- Each test server was stopped afterward.

The first test inherited a Windows command shell, so Bash was explicitly selected for the second test. For an MSYS2 Bash session, run this from the MSYS2 shell:

```sh
SHELL=/usr/bin/bash tmux new-session /usr/bin/bash
```

This verifies tmux server and pane operation on Windows through MSYS2, without WSL. Interactive attachment, rendering, keyboard/mouse behavior in a local terminal, and tmm integration were not tested.

## Linux runtime testing and Windows build diagnosis, 09/10/2026

Copied the static x86-64 Linux tmm executable to `winny` and ran it inside Ubuntu 24.04 WSL with tmux 3.4. `tmm --help` succeeded, and the integration suite reached the interactive UI using disposable PTYs and tmux sockets. Its first failure exposed an older-tmux compatibility issue: `display-message -C` is not supported by tmux 3.4.

Added a fallback in `src/backend.zig`: when tmux specifically rejects the centered-message option, retry the display message without `-C`, preserving the selected client, literal text, and five-second duration. Other errors still propagate. No libc linkage was added.

After the fix, the full Linux integration suite passed: repeated shutdown, agent status/completion/acknowledgement, inline create/rename/cancel/duplicate retry, shell and agent pane navigation, client isolation, hover/click/scroll, blink, record framing, disconnect handling, server switching, and query failures. The native macOS integration suite also passed. Final ReleaseSmall builds passed for Linux x86-64, Linux ARM64, and native macOS ARM64; native unit tests passed. Both Linux executables are static. Linux ARM64 was compile-tested only.

Retried the native x86-64 Windows build with `-freference-trace=10`. It still fails before producing an executable:

- `src/sidebar.zig`: Unix UID-based socket discovery has no Windows implementation.
- `src/main.zig`: the argument iterator requires the allocating cross-platform API on Windows.
- libtmux `src/which.zig:12`: calls `Environ.getPosix("PATH")`, causing the environment compiler error. Its PATH parsing also assumes Unix separators and executable names.

Thus tmm itself has not run against MSYS2 tmux on Windows. Linux-under-WSL testing and the earlier MSYS2 tmux test are separate results. A native Windows build needs these application/dependency changes before runtime testing is possible.
