const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const squashfuse_dep = b.dependency("squashfuse", .{
        .target = target,
        .optimize = optimize,

        // These options will be renamed in the future
        .@"enable-zlib" = true,
        .@"use-libdeflate" = true,
        .@"enable-xz" = true,
        .@"enable-lz4" = true,

        .@"enable-lzma" = false,
        .@"enable-lzo" = false,
        .@"enable-zstd" = false,
    });

    const exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // When using compression libraries implemented in C, they must be linked
    // to the main executable
    exe.linkLibrary(squashfuse_dep.artifact("deflate"));
    exe.linkLibrary(squashfuse_dep.artifact("lz4"));
    exe.linkLibrary(squashfuse_dep.artifact("lzma"));

    exe.root_module.addImport(
        "squashfuse",
        squashfuse_dep.module("squashfuse"),
    );

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
