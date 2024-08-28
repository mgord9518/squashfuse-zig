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
        .name = "import_example",
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
```
