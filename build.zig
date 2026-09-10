// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    mod.addImport("libtmux", b.dependency("libtmux", .{}).module("libtmux"));
    mod.addImport("vaxis", b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis"));
    const exe = b.addExecutable(.{ .name = "tmm", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run tmm").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/model.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Test record parsing and target identity").dependOn(&b.addRunArtifact(tests).step);
}
