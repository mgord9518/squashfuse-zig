const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // As of now, there isn't a way to disable a compression library, so every
    // one will either be statically linked in or an attempt will be made to
    // dlload it from the system
    //
    // This will be changed in the future, but the API will probably stay the
    // same
    const squashfuse_dep = b.dependency("squashfuse", .{
        .target = target,
        .optimize = optimize,

        .zlib_decompressor = .libz,
        .static_zlib = false,

        .zstd_decompressor = .libzstd,
        .static_zstd = true,
    });

    const exe = b.addExecutable(.{
        .name = "squashfs_inspector",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libc should be explicitly linked unless all compression libraries are
    // using the Zig implementation or are statically linked
    exe.linkLibC();

    exe.root_module.addImport(
        "squashfuse",
        squashfuse_dep.module("squashfuse"),
    );

    // If a C-ABI compression library is used and static building is enabled,
    // the library must be linked here
    exe.linkLibrary(squashfuse_dep.artifact("zstd"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
