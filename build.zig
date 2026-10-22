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
    // Development probe for the control-mode stream. Not installed; run with
    //   zig build cmprobe -- -S <socket> -t <session>
    const probe_mod = b.createModule(.{ .root_source_file = b.path("src/cmprobe.zig"), .target = target, .optimize = optimize });
    const probe = b.addExecutable(.{ .name = "cmprobe", .root_module = probe_mod });
    const probe_run = b.addRunArtifact(probe);
    if (b.args) |args| probe_run.addArgs(args);
    b.step("cmprobe", "Run the control-mode probe").dependOn(&probe_run.step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(probe, .{}).step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run tmm").dependOn(&run.step);
    const test_mod = b.createModule(.{ .root_source_file = b.path("src/model.zig"), .target = target, .optimize = optimize });
    test_mod.addImport("vaxis", b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis"));
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Test record parsing and target identity").dependOn(&b.addRunArtifact(tests).step);
}
