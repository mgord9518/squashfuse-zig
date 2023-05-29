const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) !void {
    const exe = b.addExecutable(.{
        .name = "squashfuse",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const enable_zlib = b.option(bool, "enable-zlib", "enable zlib decompression (default: true)") orelse true;
    const use_libdeflate = b.option(bool, "use-libdeflate", "replace zlib with libdeflate (faster implementation; default: true)") orelse true;
    const enable_lz4 = b.option(bool, "enable-lz4", "enable lz4 decompression (default: true)") orelse true;
    const enable_zstd = b.option(bool, "enable-zstd", "enable zstd decompression (default: true)") orelse true;
    const enable_xz = b.option(bool, "enable-xz", "enable xz decompression (default: false)") orelse false;
    const enable_lzo = b.option(bool, "enable-lzo", "enable lz4 decompression (default: false)") orelse false;

    // TODO: add system flags for compression algos
    const use_system_fuse = b.option(bool, "use-system-fuse", "use system FUSE3 library instead of vendored (default: true)") orelse true;
    const use_system_xz = b.option(bool, "use-system-xz", "use system XZ library instead of Zig stdlib (default: false)") orelse false;

    exe.addIncludePath("libdeflate");
    exe.addIncludePath("squashfuse");
    exe.addIncludePath("zstd/lib");

    const squashfuse_mod = b.addModule("squashfuse", .{ .source_file = .{ .path = "lib.zig" } });
    const clap_mod = b.addModule("clap", .{ .source_file = .{ .path = "zig-clap/clap.zig" } });

    exe.addModule("squashfuse", squashfuse_mod);
    exe.addModule("clap", clap_mod);

    if (enable_zlib) {
        exe.defineCMacro("ENABLE_ZLIB", null);

        if (use_libdeflate) {
            exe.defineCMacro("USE_LIBDEFLATE", null);

            exe.addCSourceFile("libdeflate/lib/adler32.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/crc32.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/deflate_decompress.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/utils.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/zlib_decompress.c", &[_][]const u8{});

            const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
            if (arch.isX86()) {
                exe.addCSourceFile("libdeflate/lib/x86/cpu_features.c", &[_][]const u8{});
            } else if (arch.isARM()) {
                exe.addCSourceFile("libdeflate/lib/arm/cpu_features.c", &[_][]const u8{});
            }
        } else {
            exe.linkSystemLibrary("zlib");
        }
    }

    if (enable_lz4) {
        exe.defineCMacro("ENABLE_LZ4", null);

        exe.addCSourceFile("lz4/lib/lz4.c", &[_][]const u8{});
    }

    // TODO: vendor LZO
    if (enable_lzo) {
        exe.defineCMacro("ENABLE_LZO", null);

        exe.linkSystemLibrary("lzo2");
    }

    if (enable_xz) {
        exe.defineCMacro("ENABLE_XZ", null);

        if (use_system_xz) {
            //    exe.addCSourceFile("xz/src/liblzma/common/stream_buffer_decoder.c", &[_][]const u8{});
            //    exe.addCSourceFile("xz/src/liblzma/delta/delta_common.c", &[_][]const u8{});

            // TODO: either fix the importing of C files here or automatically build
            // and import the static libs like so
            //exe.addObjectFile("xz/src/liblzma/.libs/liblzma.a");
            exe.linkSystemLibrary("lzma");
        }
    }

    if (enable_zstd) {
        exe.defineCMacro("ENABLE_ZSTD", null);

        exe.addCSourceFile("zstd/lib/decompress/zstd_decompress.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/decompress/zstd_decompress_block.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/decompress/zstd_ddict.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/decompress/huf_decompress.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/common/zstd_common.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/common/error_private.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/common/entropy_common.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/common/fse_decompress.c", &[_][]const u8{});
        exe.addCSourceFile("zstd/lib/common/xxhash.c", &[_][]const u8{});

        // Add x86_64-specific assembly if possible
        const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
        if (arch.isX86()) {
            exe.addCSourceFile("zstd/lib/decompress/huf_decompress_amd64.S", &[_][]const u8{});
        }
    }

    if (use_system_fuse) {
        exe.linkSystemLibrary("fuse3");
    } else {
        //    exe.addCSourceFile("libfuse/lib/fuse.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_loop.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_loop_mt.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_lowlevel.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_opt.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_signals.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/buffer.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/cuse_lowlevel.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/helper.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/modules/subdir.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/mount_util.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/fuse_log.c", &[_][]const u8{});
        //    exe.addCSourceFile("libfuse/lib/compat.c", &[_][]const u8{});

        // TODO: automatically build/ vendor
        exe.addObjectFile("libfuse/build/lib/libfuse3.a");
    }

    exe.addCSourceFile("squashfuse/fs.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/table.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/xattr.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/cache.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/dir.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/file.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/nonstd-makedev.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/nonstd-pread.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/nonstd-stat.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/stat.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/stack.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/swap.c", &[_][]const u8{});
    exe.addCSourceFile("squashfuse/decompress.c", &[_][]const u8{});

    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // TODO: add tests
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = exe.target,
        .optimize = exe.optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
