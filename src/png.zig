// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The PNG decoder libghostty-vt asks an embedder for.
//!
//! libghostty-vt parses a kitty graphics transmission of `f=100` and then has
//! to turn the payload into pixels, which it does not do itself: it calls
//! `sys.decode_png`, a `pub var` function pointer. Ghostty assigns wuffs to it,
//! but only when the terminal package is built as the application; the module
//! shape tmm uses is `artifact = .lib`, which leaves the pointer null so the
//! library carries no image dependency. A null pointer there is not a silent
//! fallback -- the load fails with `UnsupportedFormat` and the image is
//! dropped -- so every PNG transmission vanished, which is what `kitty icat`
//! and timg both send. chafa was unaffected because it sends raw RGBA.
//!
//! The decode happens once per transmission, in `LoadingImage`, and never per
//! frame: a placement is drawn from the stored RGBA. So this path is cold, and
//! clarity beats speed in it.
//!
//! Two deliberate choices:
//!
//!   - zigimg's PNG decoder is called directly rather than `Image.fromMemory`,
//!     which sniffs the format. The protocol already said this is a PNG, and a
//!     sniffing decoder would cheerfully accept a JPEG declared as `f=100` --
//!     plus it links every format zigimg knows into the binary.
//!   - the pixels are copied into a plain `[]u8` allocated here. zigimg hands
//!     back a `[]Rgba32`, and the caller frees what it gets as `[]u8`
//!     (`graphics_image.zig`: `decode_alloc.free(result.data)`). Freeing a
//!     slice under a different element type than it was allocated with is not
//!     something to rely on, so the copy buys the caller the slice it expects.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const zigimg = @import("zigimg");

const log = std.log.scoped(.png);

/// Point libghostty-vt at the decoder below.
///
/// `sys.decode_png` is process-global and read on every PNG transmission, so
/// this has to run before any terminal exists and needs to run only once.
pub fn install() void {
    ghostty.sys.decode_png = &decode;
}

/// Decode a PNG into 8-bit RGBA, which is the one format the caller stores.
///
/// The error set is the caller's: `InvalidData` for anything malformed, and
/// `OutOfMemory` passed through, because the allocator handed in is a limited
/// one and the caller reads an exhausted limit as an image too large rather
/// than as a failure of tmm.
fn decode(
    alloc: std.mem.Allocator,
    data: []const u8,
) ghostty.sys.DecodeError!ghostty.sys.Image {
    var stream = zigimg.io.ReadStream.initMemory(data);
    var image = zigimg.formats.png.PNG.readImage(alloc, &stream) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Everything else is a statement about the payload: truncated,
        // not a PNG, or a PNG variant zigimg does not read.
        else => return error.InvalidData,
    };
    defer image.deinit(alloc);

    // A no-op when the PNG was already RGBA, which is the common case for the
    // screenshots and icons these programs send.
    image.convert(alloc, .rgba32) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };

    // The caller indexes the result as width * height * 4, so the stride has
    // to be exactly four bytes with no padding. `Rgba32` is an extern struct
    // of four `align(1)` bytes in r, g, b, a order, which is the layout and
    // the order wanted; this says so out loud rather than trusting it.
    comptime std.debug.assert(@sizeOf(zigimg.color.Rgba32) == 4);
    const pixels = image.pixels.asBytes();
    const expect = @as(usize, image.width) * @as(usize, image.height) * 4;
    if (pixels.len != expect) {
        // Not reachable through a successful convert, and worth refusing
        // rather than handing the caller a buffer it will read past.
        log.warn("png decoded to an unexpected size got={} want={}", .{ pixels.len, expect });
        return error.InvalidData;
    }

    const out = try alloc.alloc(u8, pixels.len);
    @memcpy(out, pixels);
    return .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .data = out,
    };
}

/// A 2x1 PNG: one opaque red pixel, one half-transparent blue one.
///
/// The rows below are laid out one PNG chunk at a time, which `zig fmt` would
/// reflow into even rows of eight and make unreadable. This file is left
/// unformatted for that reason, as several others here are.
///
/// Written out as bytes rather than read from a file so the test is a unit
/// test and not a fixture: 8-bit RGBA, no interlacing, one IDAT, with the two
/// CRCs precomputed. Byte-for-byte what a transmission would carry.
const two_pixel_png = [_]u8{
    // signature
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    // IHDR: length 13, tag, then 2x1, bit depth 8, colour type 6 (RGBA),
    // deflate, no filter, no interlace, and the chunk CRC
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00,
    0xf4, 0x22, 0x7f, 0x8a,
    // IDAT: length 14, tag, a zlib stream of one filter byte (0) followed by
    // the eight pixel bytes, and the chunk CRC
    0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54,
    0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x42,
    0x0d, 0x00, 0x0f, 0x7a, 0x03, 0x7e,
    0x77, 0xe9, 0x7f, 0x97,
    // IEND
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
};

test "a PNG transmission decodes to RGBA in the order the caller stores" {
    const alloc = std.testing.allocator;
    const img = try decode(alloc, &two_pixel_png);
    defer alloc.free(img.data);

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    // Red first, then blue at half alpha: proves the channel order and that
    // alpha survives rather than being flattened or premultiplied.
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 0x00, 0x00, 0xff,
        0x00, 0x00, 0xff, 0x80,
    }, img.data);
}

test "a payload that is not a PNG is refused rather than decoded" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidData, decode(alloc, "not a png at all"));
    // A real header with the rest cut off: the shape a half-arrived
    // transmission has, and the one worth being sure does not read past it.
    try std.testing.expectError(error.InvalidData, decode(alloc, two_pixel_png[0..20]));
    try std.testing.expectError(error.InvalidData, decode(alloc, ""));
}

test "installing the decoder is what makes libghostty-vt accept PNG" {
    // The pointer is global, so leave it as it was found: other tests in this
    // binary build terminals and should see whatever the process had.
    const saved = ghostty.sys.decode_png;
    defer ghostty.sys.decode_png = saved;

    ghostty.sys.decode_png = null;
    try std.testing.expect(ghostty.sys.decode_png == null);
    install();
    try std.testing.expect(ghostty.sys.decode_png != null);
}
