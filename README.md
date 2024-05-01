# squashfuse-zig
WIP SquashFS implementation in Zig, modeled from squashfuse

My main goals for this project are as follows:
 * Make library usage as similar to Zig's stdlib as possible
 * Performant; choose the best compression implementations by default (this
   is already done using libdeflate in place of zlib)
 * Fully-compatible with existing squashfuse tools
 * Keep code as clean as possible (whew, yeah we're not there yet)

With some very basic benchmarking, extracting a zlib-compressed AppImage
(FreeCAD, the largest AppImage I've been able to find so far), takes 3.1
seconds using the `--extract` flag with squashfuse-zig's CLI tool, which
is currently single-thread only.

For reference, `unsquashfs` with multi-threaded decompression takes 1.5 seconds
and single-threaded takes 6.5 seconds.

Surely almost all of the single-threaded performace gain can be chalked up to
using libdeflate, but performance by default is important. I'd like to compare
it to the actual squashfuse's `squashfuse_extract` program to see how it
compares.

Importing example:
```zig
// build.zig.zon
.{
    .name = "example",
    .version = "0.0.0",

    .dependencies = .{
        .squashfuse = .{
            .url = "https://github.com/mgord9518/squashfuse-zig/archive/refs/tags/continuous.tar.gz",

            // Leave this commented initially, then Zig will complain and give
            // you the correct value
            //.hash = "1220e675672f86be446965d5b779a384c81c7648e385428ed5a8858842cfa38a4e22",
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "README.md",
    },
}
```
```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import and configure dependency
    const squashfuse_dep = b.dependency("squashfuse", .{
        .target = target,
        .optimize = optimize,

        // These options will be renamed in the future
        .@"enable-zlib" = true,
        .@"use-libdeflate" = true,
        .@"enable-xz" = false,
        .@"enable-lzma" = false,
        .@"enable-lzo" = false,
        .@"enable-lz4" = false,
        .@"enable-zstd" = false,
    });

    const exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport(
        "squashfuse",
        squashfuse_dep.module("squashfuse"),
    );

    // Link up required libraries
    // TODO: automate this
    exe.linkLibrary(squashfuse_dep.artifact("deflate"));

    b.installArtifact(exe);
}
```
