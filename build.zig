const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const lib = b.addStaticLibrary(.{
        .name = "zigroutines",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });

    lib.linkLibC();

    b.installArtifact(lib);
}
