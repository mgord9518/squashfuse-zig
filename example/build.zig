const std = @import("std");
const squashfuse = @import("squashfuse-zig/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "squashfuse_example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const squashfuse_opts = squashfuse.LinkOptions{
        .enable_lz4 = false,
        .enable_lzo = false,
        .enable_zlib = true,
        .enable_zstd = false,
        .enable_xz = false,
    };

    exe.addModule(
        "squashfuse",
        // Generates a module with the provided link options
        squashfuse.module(b, squashfuse_opts),
    );

    // Automatically link in all required files based on the build options
    squashfuse.link(exe, squashfuse_opts);

    b.installArtifact(exe);
}
