const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const lib_options = b.addOptions();

    const strip = b.option(bool, "strip", "remove debug symbols from executable") orelse false;
    lib_options.addOption(bool, "strip", strip);

    const enable_fuse = b.option(bool, "enable_fuse", "enable usersystem mounting (FUSE)") orelse true;
    const static_fuse = b.option(bool, "static_fuse", "static link FUSE") orelse true;

    const zlib_decompressor = b.option(ZlibDecompressor, "zlib_decompressor", "Decompressor to use for zlib streams") orelse .zig_stdlib;
    lib_options.addOption(ZlibDecompressor, "zlib_decompressor", zlib_decompressor);

    const xz_decompressor = b.option(XzDecompressor, "xz_decompressor", "Decompressor to use for xz streams") orelse .zig_stdlib;
    lib_options.addOption(XzDecompressor, "xz_decompressor", xz_decompressor);

    const lz4_decompressor = b.option(Lz4Decompressor, "lz4_decompressor", "Decompressor to use for lz4 streams") orelse .liblz4_dynlib;
    lib_options.addOption(Lz4Decompressor, "lz4_decompressor", lz4_decompressor);

    const zstd_decompressor = b.option(ZstdDecompressor, "zstd_decompressor", "Decompressor to use for zstd streams") orelse .zig_stdlib;
    lib_options.addOption(ZstdDecompressor, "zstd_decompressor", zstd_decompressor);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "squashfuse",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
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
    });

    const fuse_module = b.addModule(
        "fuse",
        .{ .root_source_file = fuse_dep.module("fuse").root_source_file },
    );

    const clap_module = b.addModule("clap", .{
        .root_source_file = clap_dep.path("clap.zig"),
    });

    if (enable_fuse) {
        if (static_fuse) {
            exe.linkLibrary(fuse_dep.artifact("fuse"));
        } else {
            // TODO: use DynLib
            exe.linkSystemLibrary("fuse3");
        }
    }

    switch (zlib_decompressor) {
        .libdeflate_static => {
            const lib = try buildLibdeflate(b, .{
                .name = "deflate",
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });

            b.installArtifact(lib);
            exe.linkLibrary(lib);
        },
        .libdeflate_dynamic => exe.linkSystemLibrary("deflate"),
        .libz_dynamic => exe.linkSystemLibrary("z"),
        .libdeflate_dynlib, .libz_dynlib, .zig_stdlib => {},
    }

    switch (xz_decompressor) {
        .liblzma_static => {
            const lib = try buildLiblzma(b, .{
                .name = "lzma",
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });

            b.installArtifact(lib);
            exe.linkLibrary(lib);
        },
        .liblzma_dynamic => exe.linkSystemLibrary("lzma"),
        .liblzma_dynlib, .zig_stdlib => {},
    }

    switch (lz4_decompressor) {
        .liblz4_static => {
            const lib = try buildLiblz4(b, .{
                .name = "lz4",
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });

            b.installArtifact(lib);
            exe.linkLibrary(lib);
        },
        .liblz4_dynamic => exe.linkSystemLibrary("lz4"),
        .liblz4_dynlib => {},
    }

    switch (zstd_decompressor) {
        .libzstd_static => {
            const lib = try buildLibzstd(b, .{
                .name = "zstd",
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });

            b.installArtifact(lib);
            exe.linkLibrary(lib);
        },
        .libzstd_dynamic => exe.linkSystemLibrary("zstd"),
        .libzstd_dynlib, .zig_stdlib => {},
    }

    exe.root_module.addImport("squashfuse", squashfuse_module);
    exe.root_module.addImport("fuse", fuse_module);
    exe.root_module.addImport("clap", clap_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    unit_tests.root_module.addImport("squashfuse", squashfuse_module);

    unit_tests.linkLibrary(try buildLibdeflate(b, .{
        .name = "deflate",
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

    const src_dir = comptime std.fs.path.dirname(@src().file) orelse ".";
    const cwd = std.fs.cwd();

    // Build test images if they don't exist
    inline for (.{ "zlib", "xz", "lz4", "zstd" }) |algo| {
        cwd.access(src_dir ++ "/test/tree_" ++ algo ++ ".sqfs", .{}) catch |err| {
            if (err != error.FileNotFound) return err;

            // For some reason zlib compression in SquashFS is referred to as
            // gzip. It uses zlib headers, not gzip
            const comp = if (std.mem.eql(u8, algo, "zlib")) blk: {
                break :blk "gzip";
            } else blk: {
                break :blk algo;
            };

            const make_image = b.addSystemCommand(
                &[_][]const u8{
                    "mksquashfs",
                    "-",
                    src_dir ++ "/test/tree_" ++ algo ++ ".sqfs",
                    "-quiet",
                    "-comp",
                    comp,
                    "-noappend",
                    "-root-owned",
                    // The block size should be automatically tested at different
                    // sizes in the future
                    "-b",
                    "8192",
                    "-p",
                    "/ d 644 0 0",
                    "-p",
                    "1 d 644 0 0",
                    "-p",
                    "1/TEST f 644 0 0 echo -n TEST",
                    "-p",
                    "2 d 644 0 0",
                    "-p",
                    "2/another\\ dir d 644 0 0",
                    // TODO: cross-platform sparse file creation
                    "-p",
                    "2/another\\ dir/sparse_file f 644 0 0 head -c 65536 /dev/zero",
                    "-p",
                    "2/text f 644 0 0 cat test/test.zig",
                    "-p",
                    "broken_symlink s 644 0 0 I_DONT_EXIST",
                    "-p",
                    "symlink s 644 0 0 2/text",
                    "-p",
                    ("A" ** 256) ++ " f 644 0 0 true",
                    // TODO: test timestamps
                    "-p",
                    "perm_400 F  696969 400 0 0 true",
                    "-p",
                    "perm_644 f         644 0 0 true",
                    "-p",
                    "perm_777 f         777 0 0 true",
                    "-p",
                    "block_device b     644 0 0 69 2",
                    "-p",
                    "character_device c 500 0 0 0  1",
                },
            );

            test_step.dependOn(&make_image.step);
        };
    }
}

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
    lib.defineCMacro("HAVE_CHECK_CRC32", "1");

    const arch = options.target.result.cpu.arch;

    // TODO: other archs
    // <https://github.com/winlibs/liblzma/blob/e41fdf12b0c0be6d4910f41c137deacc24279c9c/src/liblzma/common/filter_common.c>
    if (arch.isX86()) {
        lib.defineCMacro("HAVE_DECODER_X86", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/x86.c"),
        });
    } else if (arch.isARM()) {
        lib.defineCMacro("HAVE_DECODER_ARM", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/arm.c"),
        });
    } else if (arch.isAARCH64()) {
        lib.defineCMacro("HAVE_DECODER_ARM64", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/arm64.c"),
        });
    } else if (arch.isRISCV()) {
        lib.defineCMacro("HAVE_DECODER_RISCV", "1");
        lib.addCSourceFile(.{
            .file = libxz_dep.path("src/liblzma/simple/riscv.c"),
        });
    }

    lib.addCSourceFiles(.{
        .root = libxz_dep.path("."),
        .files = &.{
            "src/liblzma/check/check.c",
            "src/liblzma/check/crc32_fast.c",
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
        },
    });

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

    lib.addCSourceFiles(.{
        .root = libdeflate_dep.path("."),
        .files = &.{
            "lib/adler32.c",
            "lib/crc32.c",
            "lib/deflate_decompress.c",
            "lib/utils.c",
            "lib/zlib_decompress.c",
        },
    });

    const arch = options.target.result.cpu.arch;

    if (arch.isX86()) {
        lib.addCSourceFile(.{
            .file = libdeflate_dep.path("lib/x86/cpu_features.c"),
        });
    } else if (arch.isARM() or arch.isAARCH64()) {
        lib.addCSourceFile(.{
            .file = libdeflate_dep.path("lib/arm/cpu_features.c"),
        });
    }

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

const ZlibDecompressor = enum {
    zig_stdlib,
    libdeflate_dynamic,
    libdeflate_dynlib,
    libdeflate_static,
    libz_dynlib,
    libz_dynamic,
};

const XzDecompressor = enum {
    zig_stdlib,
    liblzma_dynamic,
    liblzma_dynlib,
    liblzma_static,
};

const ZstdDecompressor = enum {
    zig_stdlib,
    libzstd_dynamic,
    libzstd_dynlib,
    libzstd_static,
};

const Lz4Decompressor = enum {
    liblz4_dynamic,
    liblz4_dynlib,
    liblz4_static,
};
