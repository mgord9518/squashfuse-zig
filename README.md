# squashfuse-zig
SquashFS implementation in Zig, modeled after squashfuse

Active/ complete goals:
 - [ ] Library usage in line with Zig stdlib
    - [ ] (Partial) Dir implementation
    - [ ] Move Inode methods into Dir and File structs
    - [ ] File struct
 - [x] Performance; choose the fastest decompression libraries by default
       (being done for the CLI tool by default via libdeflate)
 - [x] (Partial) Compatibility with existing squashfuse tools

Future goals:
 - [ ] Writing?
 - [ ] Multithreading

Importing example:

[build.zig.zon](example/build.zig.zon)
```zig
.{
    .name = "import_example",
    .version = "0.0.0",
    .minimum_zig_version = "0.13.0",

    .dependencies = .{
        .squashfuse = .{
            //.url = "https://github.com/mgord9518/squashfuse-zig/archive/refs/tags/continuous.tar.gz",
            //.hash = "1220e675672f86be446965d5b779a384c81c7648e385428ed5a8858842cfa38a4e22",
            .path = "../",
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

[build.zig](example/build.zig)
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const squashfuse_dep = b.dependency("squashfuse", .{
        .target = target,
        .optimize = optimize,

        .zlib_decompressor = .libz_dynamic,
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
    exe.linkSystemLibrary("z");

    b.installArtifact(exe);
}
```
