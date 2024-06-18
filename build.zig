const std = @import("std");
const builtin = @import("builtin");

var option_list: std.StringHashMap(bool) = undefined;

pub fn build(b: *std.Build) !void {
    const options = .{
        .{ "strip", "remove debug info", false },
        .{ "use-system-fuse", "use system FUSE3 library instead of vendored", false },
        .{ "enable-fuse", "build with support for FUSE mounting", true },

        .{ "use-libdeflate", "replace zlib with faster libdeflate implementation", true },
        .{ "use-zig-zlib", "replace zlib with Zig stdlib zlib", false },
        .{ "use-zig-xz", "replace liblzma with Zig stdlib XZ", true },
        .{ "use-zig-zstd", "replace liblzma with Zig stdlib ZSTD", false },

        .{ "enable-zlib", "enable zlib decompression. medium ratio, medium speed", true },
        .{ "enable-lzma", "deprecated and not yet supported", false },
        .{ "enable-lzo", "enable lzo decompression. low ratio, fast speed", true },
        .{ "enable-xz", "enable xz decompression. very high ratio, slow speed", true },
        .{ "enable-lz4", "enable lz4 decompression. low ratio, very fast speed", true },
        .{ "enable-zstd", "enable zstd decompression. high ratio, fast speed", true },
    };

    option_list = std.StringHashMap(bool).init(b.allocator);

    const lib_options = b.addOptions();
    inline for (options) |option| {
        const opt = b.option(
            bool,
            option[0],
            option[1],
        ) orelse option[2];

        // TODO: There's probably a much better way to do this
        try option_list.put(option[0], opt);

        lib_options.addOption(bool, option[0], opt);
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "squashfuse",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = option_list.get("strip").?,
    });

    const squashfuse_module = b.addModule("squashfuse", .{
        .root_source_file = b.path("lib/root.zig"),
        .imports = &.{
            .{
                .name = "build_options",
                .module = lib_options.createModule(),
            },
        },
    });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const fuse_dep = b.dependency("fuse", .{
        .target = target,
        .optimize = optimize,
        //.use_system_fuse = option_list.get("use-system-fuse").?,
    });

    const fuse_module = b.addModule(
        "fuse",
        .{ .root_source_file = fuse_dep.module("fuse").root_source_file },
    );

    const clap_module = b.addModule("clap", .{
        .root_source_file = clap_dep.path("clap.zig"),
    });

    if (option_list.get("enable-fuse").?) {
        const os = target.result.os.tag;
        if (os != .linux) {
            const error_string = try std.fmt.allocPrint(
                b.allocator,
                \\FUSE support for {s} not yet implemented
                \\please build with `-Denable-fuse=false`
            ,
                .{@tagName(os)},
            );

            // TODO: surely panic should be replaced with a better option
            // here?
            @panic(error_string);
        }

        if (option_list.get("use-system-fuse").?) {
            exe.linkSystemLibrary("fuse3");
        } else {
            //b.installArtifact(fuse_dep.artifact("fuse"));
            exe.linkLibrary(fuse_dep.artifact("fuse"));
        }
    }

    if (option_list.get("enable-zlib").? and !option_list.get("use-zig-zlib").?) {
        if (option_list.get("use-libdeflate").?) {
            const lib = try buildLibdeflate(b, .{
                .name = "deflate",
                .target = target,
                .optimize = optimize,
                .strip = option_list.get("strip").?,
            });

            b.installArtifact(lib);
            exe.linkLibrary(lib);
        } else {
            // TODO: maybe vendor zlib? Idk, I don't see the benefit. Anyone
            // I imagine specifically choosing zlib probably wants it as it's
            // a system library on essentially every Linux distro
            exe.linkSystemLibrary("zlib");
        }
    }

    if (option_list.get("enable-lzo").?) {
        const lib = try buildLiblzo(b, .{
            .name = "lzo",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        });

        b.installArtifact(lib);
        exe.linkLibrary(lib);
    }

    if (option_list.get("enable-xz").? and !option_list.get("use-zig-xz").?) {
        const lib = try buildLiblzma(b, .{
            .name = "lzma",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        });

        b.installArtifact(lib);
        exe.linkLibrary(lib);
    }

    if (option_list.get("enable-lz4").?) {
        const lib = try buildLiblz4(b, .{
            .name = "lz4",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        });

        b.installArtifact(lib);
        exe.linkLibrary(lib);
    }

    if (option_list.get("enable-zstd").? and !option_list.get("use-zig-zstd").?) {
        const lib = try buildLibzstd(b, .{
            .name = "zstd",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        });

        b.installArtifact(lib);
        exe.linkLibrary(lib);
    }

    exe.root_module.addImport("squashfuse", squashfuse_module);
    exe.root_module.addImport("fuse", fuse_module);
    exe.root_module.addImport("clap", clap_module);

    b.installArtifact(exe);

    // TODO: create symlinks in install directory
    //    if (build_squashfuse_tool) {
    //        const cwd = std.fs.cwd();
    //
    //        cwd.symLink("squashfuse_tool", "zig-out/bin/squashfuse_ls", .{}) catch {};
    //        cwd.symLink("squashfuse_tool", "zig-out/bin/squashfuse_extract", .{}) catch {};
    //    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //    var build_test_images_step = std.Build.Step.init(.{
    //        .id = .custom,
    //        .name = "images",
    //        .owner = b,
    //        .makeFn = makeTestImages,
    //    });

    try makeTestImages(b);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = option_list.get("strip").?,
    });

    unit_tests.root_module.addImport("squashfuse", squashfuse_module);

    unit_tests.linkLibrary(try buildLibdeflate(b, .{
        .name = "deflate",
        .target = target,
        .optimize = optimize,
    }));

    unit_tests.linkLibrary(try buildLiblzo(b, .{
        .name = "lzo",
        .target = target,
        .optimize = optimize,
    }));

    unit_tests.linkLibrary(try buildLiblzma(b, .{
        .name = "lzma",
        .target = target,
        .optimize = optimize,
    }));

    unit_tests.linkLibrary(try buildLiblz4(b, .{
        .name = "lz4",
        .target = target,
        .optimize = optimize,
    }));

    unit_tests.linkLibrary(try buildLibzstd(b, .{
        .name = "zstd",
        .target = target,
        .optimize = optimize,
    }));

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    //test_step.dependOn(&build_test_images_step);
}

//pub fn makeTestImages(step: *std.Build.Step, prog_node: *std.Progress.Node) anyerror!void {
pub fn makeTestImages(b: *std.Build) anyerror!void {
    _ = b;
    const allocator = std.heap.page_allocator;
    //const b = step.owner;
    //_ = prog_node;

    // Generate test SquashFS images using pseudo file definitions
    // TODO: move this into a build step and cache already built images
    const src_dir = comptime std.fs.path.dirname(@src().file) orelse ".";
    inline for (.{ "zlib", "xz", "lzo", "lz4", "zstd" }) |algo| {
        // For some reason zlib compression in SquashFS is referred to as
        // gzip. It uses zlib headers, not gzip
        const comp = if (std.mem.eql(u8, algo, "zlib")) blk: {
            break :blk "gzip";
        } else blk: {
            break :blk algo;
        };

        _ = try std.process.Child.run(.{
            .allocator = allocator,

            // zig fmt: off
            .argv = &.{
                "mksquashfs",
                "-",
                src_dir ++ "/test/tree_" ++ algo ++ ".sqfs",
                "-comp", comp,
                "-noappend",
                "-root-owned",
                // The block size should be automatically tested at different
                // sizes in the future
                "-b", "1M",
                "-p", "/ d 644 0 0",
                "-p", "1 d 644 0 0",
                "-p", "1/TEST f 644 0 0 echo -n TEST",
                "-p", "2 d 644 0 0",
                "-p", "2/another\\ dir d 644 0 0",
                // TODO: cross-platform sparse file creation
                "-p", "2/another\\ dir/sparse_file f 644 0 0 head -c 65536 /dev/zero",
                "-p", "2/text f 644 0 0 cat test/test.zig",
                "-p", "broken_symlink s 644 0 0 I_DONT_EXIST",
                "-p", "symlink s 644 0 0 2/text",
                "-p", ("A" ** 256) ++ " f 644 0 0 true",
                // TODO: test timestamps
                "-p", "perm_400 F  696969 400 0 0 true",
                "-p", "perm_644 f         644 0 0 true",
                "-p", "perm_777 f         777 0 0 true",
                "-p", "block_device b     644 0 0 69 2",
                "-p", "character_device c 500 0 0 0  1",
            },
            // zig fmt: on
        });
    }
}

// TODO: replace with
pub fn buildLiblzma(
    b: *std.Build,
    options: std.Build.ExecutableOptions,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "lzma",
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip orelse false,
    });

    const libxz_dep = b.dependency("libxz", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    lib.addIncludePath(libxz_dep.path("src/common"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/api"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/check"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/common"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/rangecoder"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/delta"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/lz"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/lzma"));
    lib.addIncludePath(libxz_dep.path("src/liblzma/simple"));

    lib.defineCMacro("HAVE_STDBOOL_H", "1");
    lib.defineCMacro("HAVE_STDINT_H", "1");
    lib.defineCMacro("HAVE_DECODER_LZMA1", "1");
    lib.defineCMacro("HAVE_DECODER_LZMA2", "1");

    lib.defineCMacro("HAVE_SMALL", "1");

    const c_files = &[_][]const u8{
        "src/liblzma/check/check.c",
        "src/liblzma/check/crc32_small.c",
        "src/liblzma/check/crc32_table.c",
        "src/liblzma/common/block_decoder.c",
        "src/liblzma/common/block_header_decoder.c",
        "src/liblzma/common/block_util.c",
        "src/liblzma/common/common.c",
        "src/liblzma/common/filter_common.c",
        "src/liblzma/common/filter_decoder.c",
        "src/liblzma/common/filter_flags_decoder.c",
        "src/liblzma/common/index_hash.c",
        "src/liblzma/common/stream_buffer_decoder.c",
        "src/liblzma/common/stream_decoder.c",
        "src/liblzma/common/stream_flags_common.c",
        "src/liblzma/common/stream_flags_decoder.c",
        "src/liblzma/common/vli_decoder.c",
        "src/liblzma/common/vli_size.c",
        "src/liblzma/lz/lz_decoder.c",
        "src/liblzma/lzma/lzma2_decoder.c",
        "src/liblzma/lzma/lzma_decoder.c",
        "src/liblzma/simple/simple_coder.c",
        "src/liblzma/simple/simple_decoder.c",
    };

    const arch = options.target.result.cpu.arch;

    // TODO: other archs
    // <https://github.com/winlibs/liblzma/blob/e41fdf12b0c0be6d4910f41c137deacc24279c9c/src/liblzma/common/filter_common.c>
    if (arch.isX86()) {
        lib.defineCMacro("HAVE_DECODER_X86", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/x86.c"),
            .flags = &[_][]const u8{},
        });
    }

    if (arch.isARM()) {
        lib.defineCMacro("HAVE_DECODER_ARM", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/arm.c"),
            .flags = &[_][]const u8{},
        });
    }

    for (c_files) |c_file| {
        lib.addCSourceFile(.{
            .file = libxz_dep.path(c_file),
            .flags = &[_][]const u8{},
        });
    }

    lib.linkLibC();

    return lib;
}

pub fn buildLibdeflate(
    b: *std.Build,
    options: std.Build.ExecutableOptions,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "deflate",
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip orelse false,
    });

    const libdeflate_dep = b.dependency("libdeflate", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    const c_files = &[_][]const u8{
        "lib/adler32.c",
        "lib/crc32.c",
        "lib/deflate_decompress.c",
        "lib/utils.c",
        "lib/zlib_decompress.c",
    };

    for (c_files) |c_file| {
        lib.addCSourceFile(.{
            .file = libdeflate_dep.path(c_file),
            .flags = &[_][]const u8{},
        });
    }

    const arch = options.target.result.cpu.arch;

    if (arch.isX86()) {
        lib.addCSourceFile(.{
            .file = libdeflate_dep.path("lib/x86/cpu_features.c"),
            .flags = &[_][]const u8{},
        });
    } else if (arch.isARM() or arch.isAARCH64()) {
        lib.addCSourceFile(.{
            .file = libdeflate_dep.path("lib/arm/cpu_features.c"),
            .flags = &[_][]const u8{},
        });
    }

    lib.linkLibC();

    return lib;
}

pub fn buildLiblzo(
    b: *std.Build,
    options: std.Build.ExecutableOptions,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "lzo",
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip orelse false,
    });

    const liblzo_dep = b.dependency("libminilzo", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    lib.addCSourceFile(.{
        .file = liblzo_dep.path("minilzo.c"),
        .flags = &[_][]const u8{},
    });

    lib.linkLibC();

    return lib;
}

pub fn buildLiblz4(
    b: *std.Build,
    options: std.Build.ExecutableOptions,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "lz4",
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip orelse false,
    });

    const liblz4_dep = b.dependency("liblz4", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    lib.addCSourceFile(.{
        .file = liblz4_dep.path("lib/lz4.c"),
        .flags = &[_][]const u8{},
    });

    lib.linkLibC();

    return lib;
}

pub fn buildLibzstd(
    b: *std.Build,
    options: std.Build.ExecutableOptions,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "zstd",
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip orelse false,
    });

    const libzstd_dep = b.dependency("libzstd", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    lib.addCSourceFiles(.{
        .root = libzstd_dep.path("."),
        .files = &.{
            "lib/decompress/zstd_decompress.c",
            "lib/decompress/zstd_decompress_block.c",
            "lib/decompress/zstd_ddict.c",
            "lib/decompress/huf_decompress.c",
            "lib/common/zstd_common.c",
            "lib/common/error_private.c",
            "lib/common/entropy_common.c",
            "lib/common/fse_decompress.c",
            "lib/common/xxhash.c",
        },
    });

    const arch = options.target.result.cpu.arch;

    // Add x86_64-specific assembly if possible
    if (arch.isX86()) {
        lib.addAssemblyFile(libzstd_dep.path(
            "lib/decompress/huf_decompress_amd64.S",
        ));
    }

    lib.linkLibC();

    return lib;
}
