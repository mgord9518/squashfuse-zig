const std = @import("std");
const builtin = @import("builtin");

var option_list: std.StringHashMap(bool) = undefined;

pub fn build(b: *std.Build) !void {
    const options = .{
        .{ "strip", "remove debug info", false },
        .{ "use-system-fuse", "use system FUSE3 library instead of vendored", false },
        .{ "enable-fuse", "build with support for FUSE mounting", true },

        .{ "use-libdeflate", "replace zlib with faster libdeflate implementation", true },
        .{ "use-zig-xz", "replace liblzma with Zig stdlib XZ", true },
        .{ "use-zig-zstd", "replace liblzma with Zig stdlib ZSTD", false },

        .{ "enable-zlib", "enable zlib decompression. medium ratio, medium speed", true },
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
        .root_source_file = .{ .path = "src/squashfuse.zig" },
        .target = target,
        .optimize = optimize,
        .strip = option_list.get("strip").?,
    });

    const squashfuse_module = b.addModule("squashfuse", .{
        .root_source_file = .{
            .path = "lib.zig",
        },
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
        if (option_list.get("use-system-fuse").?) {
            exe.linkSystemLibrary("fuse3");
        } else {
            exe.linkLibrary(fuse_dep.artifact("fuse"));
        }
    }

    if (option_list.get("enable-zlib").?) {
        if (option_list.get("use-libdeflate").?) {
            exe.linkLibrary(try buildLibdeflate(b, .{
                .name = "deflate",
                .target = target,
                .optimize = optimize,
                .strip = option_list.get("strip").?,
            }));
        } else {
            // TODO: maybe vendor zlib? Idk, I don't see the benefit. Anyone
            // I imagine specifically choosing zlib probably wants it as it's
            // a system library on essentially every Linux distro
            exe.linkSystemLibrary("zlib");
        }
    }

    if (option_list.get("enable-lzo").?) {
        exe.linkLibrary(try buildLiblzo(b, .{
            .name = "lzo",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        }));
    }

    //    if (option_list.get("enable-xz").? and !option_list.get("use-zig-xz").?) {
    //        lib.linkLibrary(try buildLiblzma(b, .{
    //            .name = "lzma",
    //            .target = target,
    //            .optimize = optimize,
    //            .strip = strip,
    //        }));
    //    }

    if (option_list.get("enable-lz4").?) {
        exe.linkLibrary(try buildLiblz4(b, .{
            .name = "lz4",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        }));
    }

    if (option_list.get("enable-zstd").? and !option_list.get("use-zig-zstd").?) {
        exe.linkLibrary(try buildLibzstd(b, .{
            .name = "zstd",
            .target = target,
            .optimize = optimize,
            .strip = option_list.get("strip").?,
        }));
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

    // TODO: fix tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "test/test.zig" },
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

    //        unit_tests.linkLibrary(try buildLiblzma(b, .{
    //            .name = "lzma",
    //            .target = target,
    //            .optimize = optimize,
    //        }));

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
