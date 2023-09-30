# squashfuse-zig
Idomatic Zig bindings for squashfuse and new tools

My main goals for this project are as follows:
 * Make library usage as similar to Zig's stdlib as possible
 * Performant; choose the best compression implementations by default (this
   is already done using libdeflate in place of zlib)
 * Fully-compatible with existing squashfuse tools
 * Keep code as clean as possible
 * Iteratively re-implement squashfuse functionality in Zig, so eventually this
   should be a complete re-implementation. A few functions have been ported
   but the vast majority is still just bindings

With some very basic benchmarking, extracting a zlib-compressed AppImage
(FreeCAD, the largest AppImage I've been able to find so far), takes 3.7
seconds using squashfuse-zig's `squashfuse_tool`. Currently, `squashfs_tool`
is single-thread only.

For reference, `unsquashfs` with multi-threaded decompression takes 1.57 seconds
and single-threaded takes 6.5 seconds.

Surely almost all of the single-threaded performace gain can be chalked up to
using libdeflate, but performance by default is important. I'd like to compare
it to the actual squashfuse's `squashfuse_extract` program to see how it
compares.

Importing example:
```zig
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
```
