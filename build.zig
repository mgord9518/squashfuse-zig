const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    // TODO: add system flags for compression algos
    const strip = b.option(
        bool,
        "strip",
        "do not include debug info (default: false)",
    ) orelse false;

    const use_system_fuse = b.option(
        bool,
        "use-system-fuse",
        "use system FUSE3 library instead of vendored (default: false)",
    ) orelse false;

    const enable_zlib = b.option(
        bool,
        "enable-zlib",
        "enable zlib decompression (default: true)",
    ) orelse true;

    const use_libdeflate = b.option(
        bool,
        "use-libdeflate",
        "replace zlib with libdeflate (faster implementation; default: true)",
    ) orelse true;

    const enable_lz4 = b.option(
        bool,
        "enable-lz4",
        "enable lz4 decompression (default: true)",
    ) orelse true;

    const enable_zstd = b.option(
        bool,
        "enable-zstd",
        "enable zstd decompression (default: true)",
    ) orelse true;

    const use_zig_zstd = b.option(
        bool,
        "use-zig-zstd",
        "use Zig stdlib zstd implementation (default: false)",
    ) orelse false;

    const enable_xz = b.option(
        bool,
        "enable-xz",
        "enable xz decompression (default: true)",
    ) orelse true;

    const use_zig_xz = b.option(
        bool,
        "use-zig-xz",
        "use Zig stdlib xz implementation (default: true)",
    ) orelse true;

    const enable_lzo = b.option(
        bool,
        "enable-lzo",
        "enable lzo decompression (default: true)",
    ) orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "squashfuse",
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const exe = b.addExecutable(.{
        .name = "squashfuse",
        .root_source_file = .{ .path = "src/squashfuse.zig" },
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const lib_options = b.addOptions();
    lib_options.addOption(bool, "enable_xz", enable_xz);
    lib_options.addOption(bool, "enable_zlib", enable_zlib);
    lib_options.addOption(bool, "use_libdeflate", use_libdeflate);
    lib_options.addOption(bool, "enable_lzo", enable_lzo);
    lib_options.addOption(bool, "enable_lz4", enable_lz4);
    lib_options.addOption(bool, "enable_zstd", enable_zstd);
    lib_options.addOption(bool, "use_zig_zstd", use_zig_zstd);
    lib_options.addOption(bool, "use_zig_xz", use_zig_xz);

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
        //.use_system_fuse = use_system_fuse,
    });

    const fuse_module = b.addModule(
        "fuse",
        .{ .root_source_file = fuse_dep.module("fuse").root_source_file },
    );

    const clap_module = b.addModule("clap", .{
        .root_source_file = clap_dep.path("clap.zig"),
    });

    //    if (enable_fuse) {
    if (use_system_fuse) {
        lib.linkSystemLibrary("fuse3");
    } else {
        lib.linkLibrary(fuse_dep.artifact("fuse"));
    }
    //    }

    const arch = target.result.cpu.arch;
    if (enable_zlib) {
        if (use_libdeflate) {
            const libdeflate_dep = b.dependency("libdeflate", .{
                .target = target,
                .optimize = optimize,
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
        } else {
            // TODO: maybe vendor zlib? Idk, I don't see the benefit. Anyone
            // I imagine anyone specifically choosing zlib probably wants it
            // as it's a system library on essentially every Linux distro ever
            // created
            lib.linkSystemLibrary("zlib");
        }
    }

    if (enable_lz4) {
        const liblz4_dep = b.dependency("liblz4", .{
            .target = target,
            .optimize = optimize,
        });

        lib.addCSourceFile(.{
            .file = liblz4_dep.path("lib/lz4.c"),
            .flags = &[_][]const u8{},
        });
    }

    if (enable_lzo) {
        const liblzo_dep = b.dependency("libminilzo", .{
            .target = target,
            .optimize = optimize,
        });

        lib.addCSourceFile(.{
            .file = liblzo_dep.path("minilzo.c"),
            .flags = &[_][]const u8{},
        });
    }

    if (enable_xz and !use_zig_xz) {
        const libxz_dep = b.dependency("libxz", .{
            .target = target,
            .optimize = optimize,
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
            //"src/liblzma/check/crc32_fast.c",
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
    }

    if (enable_zstd and !use_zig_zstd) {
        const libzstd_dep = b.dependency("libzstd", .{
            .target = target,
            .optimize = optimize,
        });

        const c_files = &[_][]const u8{
            "lib/decompress/zstd_decompress.c",
            "lib/decompress/zstd_decompress_block.c",
            "lib/decompress/zstd_ddict.c",
            "lib/decompress/huf_decompress.c",
            "lib/common/zstd_common.c",
            "lib/common/error_private.c",
            "lib/common/entropy_common.c",
            "lib/common/fse_decompress.c",
            "lib/common/xxhash.c",
        };

        for (c_files) |c_file| {
            lib.addCSourceFile(.{
                .file = libzstd_dep.path(c_file),
                .flags = &[_][]const u8{},
            });
        }

        // Add x86_64-specific assembly if possible
        if (arch.isX86()) {
            // TODO: LazyPath for `addAssemblyFile`?
            // Calling `addCSourceFile` instead works, but is obviously suboptimal
            lib.addCSourceFile(.{
                .file = libzstd_dep.path("lib/decompress/huf_decompress_amd64.S"),
                .flags = &[_][]const u8{},
            });
        }
    }

    exe.root_module.addImport("squashfuse", squashfuse_module);
    exe.root_module.addImport("fuse", fuse_module);
    exe.root_module.addImport("clap", clap_module);

    exe.linkLibrary(lib);

    b.installArtifact(lib);
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
    // For some reason, testing with `-Dtarget=x86_64-linux-musl` fails with
    // xz reporting error 9 (LZMA_DATA_ERROR) which means data corrupt, but
    // has no issue when the target is linux-gnu.
    //
    // Even stranger, simply building with linux-musl then mounting an archive
    // appears to work as intended, including reading from files. This makes
    // me assume that xz is being built correctly and the tests are somehow
    // misconfigured. Test fails with not being able to obtain the root inode
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "test/test.zig" },
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    unit_tests.root_module.addImport("squashfuse", squashfuse_module);

    unit_tests.linkLibrary(lib);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
