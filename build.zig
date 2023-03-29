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
    const use_system_fuse = b.option(bool, "use-system-fuse", "prefer system FUSE3 library instead of vendored (default: true)") orelse true;

    exe.addIncludePath("libdeflate");
    exe.addIncludePath("squashfuse");

    const squashfuse_mod = b.addModule("squashfuse", .{ .source_file = .{ .path = "../squashfuse-zig/lib.zig" } });

    exe.addModule("squashfuse", squashfuse_mod);

    var allocator = std.heap.page_allocator;
    var config_args = std.ArrayList([]const u8).init(allocator);
    defer config_args.deinit();

    if (enable_zlib) {
        try config_args.append("-D ENABLE_ZLIB=1");

        if (use_libdeflate) {
            try config_args.append("-D USE_LIBDEFLATE=1");

            exe.addCSourceFile("libdeflate/lib/adler32.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/crc32.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/deflate_decompress.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/utils.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/zlib_decompress.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/x86/cpu_features.c", &[_][]const u8{});
            exe.addCSourceFile("libdeflate/lib/arm/cpu_features.c", &[_][]const u8{});
        } else {
            exe.linkSystemLibrary("zlib");
        }
    }

    if (enable_lz4) {
        try config_args.append("-D ENABLE_LZ4=1");

        exe.addCSourceFile("lz4/lib/lz4.c", &[_][]const u8{});
    }

    // TODO: vendor LZO
    if (enable_lzo) {
        try config_args.append("-D ENABLE_LZO=1");

        exe.linkSystemLibrary("lzo2");
    }

    if (enable_xz) {
        try config_args.append("-D ENABLE_XZ=1");

        //    exe.addCSourceFile("xz/src/liblzma/common/stream_buffer_decoder.c", &[_][]const u8{});
        //    exe.addCSourceFile("xz/src/liblzma/delta/delta_common.c", &[_][]const u8{});

        // TODO: either fix the importing of C files here or automatically build
        // and import the static libs like so
        //exe.addObjectFile("xz/src/liblzma/.libs/liblzma.a");
        exe.linkSystemLibrary("lzma");
    }

    if (enable_zstd) {
        try config_args.append("-D ENABLE_ZSTD=1");

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
        if (exe.target.cpu_arch) |arch| {
            if (arch == .x86_64) {
                exe.addCSourceFile("zstd/lib/decompress/huf_decompress_amd64.S", &[_][]const u8{});
            }
        } else if (builtin.cpu.arch == .x86_64) {
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

    // TODO: automatically include these when importing the bindings
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
    exe.addCSourceFile("squashfuse/decompress.c", config_args.items);

    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
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
