const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const squashfuse_dep = b.dependency("squashfuse", .{
        .target = target,
        .optimize = optimize,

        //.zlib_decompressor = .libz_dynamic,
        .zlib_decompressor = .libdeflate_static,
        .zstd_decompressor = .libzstd_static,
    });

    const exe = b.addExecutable(.{
        .name = "squashfs_inspector",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libc must be explicitly linked unless all compression libraries are
    // using Zig implementations
    exe.linkLibC();

    exe.root_module.addImport(
        "squashfuse",
        squashfuse_dep.module("squashfuse"),
    );

    // If a C-ABI compression library is used and isn't linked at runtime,
    // the libraries must be linked in the build script as well
    exe.linkLibrary(squashfuse_dep.artifact("zstd"));
    exe.linkLibrary(squashfuse_dep.artifact("deflate"));
    //exe.linkSystemLibrary("z");

    b.installArtifact(exe);
}
