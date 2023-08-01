const std = @import("std");
const builtin = @import("builtin");

fn initExecutable(b: *std.build.Builder, name: []const u8) !*std.Build.Step.Compile {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "src/{s}.zig", .{name});

    return b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = path },
    });
}

pub fn build(b: *std.build.Builder) !void {
    const allocator = b.allocator;

    // TODO: add system flags for compression algos
    const use_system_fuse = b.option(bool, "use-system-fuse", "use system FUSE3 library instead of vendored (default: true)") orelse true;
    const enable_zlib = b.option(bool, "enable-zlib", "enable zlib decompression (default: true)") orelse true;
    const use_libdeflate = b.option(bool, "use-libdeflate", "replace zlib with libdeflate (faster implementation; default: true)") orelse true;
    const enable_lz4 = b.option(bool, "enable-lz4", "enable lz4 decompression (default: true)") orelse true;
    const enable_zstd = b.option(bool, "enable-zstd", "enable zstd decompression (default: true)") orelse true;
    const use_zig_zstd = b.option(bool, "use-zig-zstd", "use Zig stdlib zstd implementation (default: false)") orelse false;
    const enable_xz = b.option(bool, "enable-xz", "enable xz decompression (default: false)") orelse false;
    const enable_lzo = b.option(bool, "enable-lzo", "enable lz4 decompression (default: false)") orelse false;

    const build_squashfuse = b.option(bool, "build-squashfuse", "whether or not to build main squashfuse executable(default: true)") orelse true;
    const build_squashfuse_ls = b.option(bool, "build-squashfuse_ls", "whether or not to build extra squashfuse_ls executable(default: true)") orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const executable_names = &[_]?[]const u8{
        if (build_squashfuse) "squashfuse" else null,
        if (build_squashfuse_ls) "squashfuse_ls" else null,
    };

    var executable_list = std.ArrayList(*std.Build.Step.Compile).init(allocator);
    for (executable_names) |executable| {
        if (executable) |name| {
            try executable_list.append(try initExecutable(b, name));
        }
    }

    const abi = executable_list.items[0].target.getAbi();

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_xz", enable_xz);
    exe_options.addOption(bool, "enable_zlib", enable_zlib);
    exe_options.addOption(bool, "use_libdeflate", use_libdeflate);
    exe_options.addOption(bool, "enable_lzo", enable_lzo);
    exe_options.addOption(bool, "enable_lz4", enable_lz4);
    exe_options.addOption(bool, "enable_zstd", enable_zstd);
    exe_options.addOption(bool, "use_zig_zstd", use_zig_zstd);

    const squashfuse_mod = b.addModule("squashfuse", .{
        .source_file = .{
            .path = "lib.zig",
        },
        .dependencies = &.{
            .{
                .name = "build_options",
                .module = exe_options.createModule(),
            },
        },
    });

    const clap_mod = b.addModule("clap", .{
        .source_file = .{ .path = "zig-clap/clap.zig" },
    });

    for (executable_list.items) |exe| {
        exe.target = target;
        exe.optimize = optimize;

        linkVendored(exe, .{
            .enable_lz4 = enable_lz4,
            .enable_lzo = enable_lzo,
            .enable_zlib = enable_zlib,
            .enable_zstd = enable_zstd,
            .enable_xz = enable_xz,

            .enable_fuse = std.mem.eql(u8, exe.name, "squashfuse"),
            .use_system_fuse = use_system_fuse,

            .use_libdeflate = use_libdeflate,

            .squashfuse_dir = "./",
        });

        exe.addModule("squashfuse", squashfuse_mod);
        exe.addModule("clap", clap_mod);

        if (std.mem.eql(u8, exe.name, "squashfuse")) {
            // Cannot currently build with FUSE when using musl, so sadly the
            // main program must be skipped with musl ABI
            if (abi == .musl) {
                std.debug.print("Main squashfuse tool not yet supported for MUSL libc\n", .{});
                std.debug.print("This is due to Zig not yet supporting C bitfields and\n", .{});
                std.debug.print("MUSL uses bitfields for the timespec implementation...\n", .{});
                std.debug.print("which is used by libFUSE.\n\n", .{});
                std.debug.print("Unfortunately, this means mounting cannot currently be\n", .{});
                std.debug.print("done with these bindings under MUSL unless I can find another good\n", .{});
                std.debug.print("FUSE library written in C, C++ or ideally, Zig that somehow doesn't use timespec\n", .{});
                std.debug.print("Until then, we'll have to deal with no static executables\n\n", .{});
                std.debug.print("All tools that do not require mounting will still be built\n", .{});
                continue;
            }
        }

        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(executable_list.items[0]);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // TODO: Fix tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "lib/test.zig" },
        .target = executable_list.items[0].target,
        .optimize = executable_list.items[0].optimize,
    });

    linkVendored(unit_tests, .{
        .enable_lz4 = true,
        // TODO: add LZO
        .enable_lzo = false,
        .enable_zlib = true,
        .enable_zstd = true,
        .enable_xz = true,

        // TODO: test with libdeflate disabled
        .use_libdeflate = true,

        .squashfuse_dir = "./",
    });

    const test_options = b.addOptions();
    test_options.addOption(bool, "enable_xz", true);
    test_options.addOption(bool, "enable_zlib", true);
    test_options.addOption(bool, "use_libdeflate", true);
    test_options.addOption(bool, "enable_lzo", false);
    test_options.addOption(bool, "enable_lz4", true);
    test_options.addOption(bool, "enable_zstd", true);
    test_options.addOption(bool, "use_zig_zstd", true);

    const squashfuse_test_mod = b.addModule("squashfuse", .{
        .source_file = .{
            .path = "lib.zig",
        },
        .dependencies = &.{
            .{
                .name = "build_options",
                .module = test_options.createModule(),
            },
        },
    });

    unit_tests.addModule("squashfuse", squashfuse_test_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

pub const LinkOptions = struct {
    enable_zstd: bool,
    enable_lz4: bool,
    enable_lzo: bool,
    enable_zlib: bool,
    enable_xz: bool,

    enable_fuse: bool = false,
    use_system_fuse: bool = true,

    use_libdeflate: bool = true,

    squashfuse_dir: []const u8,
};

// TODO: remove leak
fn append(parent: []const u8, child: []const u8) []const u8 {
    var allocator = std.heap.page_allocator;

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child }) catch unreachable;
}

pub fn linkVendored(exe: *std.Build.Step.Compile, opts: LinkOptions) void {
    const prefix = opts.squashfuse_dir;

    if (opts.enable_zlib) {
        if (opts.use_libdeflate) {
            exe.addIncludePath(.{ .path = append(prefix, "libdeflate") });

            exe.addCSourceFiles(&[_][]const u8{
                append(prefix, "libdeflate/lib/adler32.c"),
                append(prefix, "libdeflate/lib/crc32.c"),
                append(prefix, "libdeflate/lib/deflate_decompress.c"),
                append(prefix, "libdeflate/lib/utils.c"),
                append(prefix, "libdeflate/lib/zlib_decompress.c"),
            }, &[_][]const u8{});

            const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
            if (arch.isX86()) {
                exe.addCSourceFile(.{
                    .file = .{ .path = append(prefix, "libdeflate/lib/x86/cpu_features.c") },
                    .flags = &[_][]const u8{},
                });
            } else if (arch.isARM()) {
                exe.addCSourceFile(.{
                    .file = .{ .path = append(prefix, "libdeflate/lib/arm/cpu_features.c") },
                    .flags = &[_][]const u8{},
                });
            }
        } else {
            exe.linkSystemLibrary("zlib");
        }
    }

    if (opts.enable_fuse) {
        if (opts.use_system_fuse) {
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
            exe.addObjectFile(.{ .path = "libfuse/build/lib/libfuse3.a" });
        }
    }

    if (opts.enable_lz4) {
        exe.addIncludePath(.{ .path = append(prefix, "lz4/lib") });
        exe.addCSourceFile(.{
            .file = .{ .path = append(prefix, "lz4/lib/lz4.c") },
            .flags = &[_][]const u8{},
        });
    }

    // TODO: vendor LZO
    if (opts.enable_lzo) {
        exe.linkSystemLibrary("lzo2");
    }

    if (opts.enable_zstd) {
        exe.addIncludePath(.{ .path = append(prefix, "zstd/lib") });

        exe.addCSourceFiles(&[_][]const u8{
            append(prefix, "zstd/lib/decompress/zstd_decompress.c"),
            append(prefix, "zstd/lib/decompress/zstd_decompress_block.c"),
            append(prefix, "zstd/lib/decompress/zstd_ddict.c"),
            append(prefix, "zstd/lib/decompress/huf_decompress.c"),
            append(prefix, "zstd/lib/common/zstd_common.c"),
            append(prefix, "zstd/lib/common/error_private.c"),
            append(prefix, "zstd/lib/common/entropy_common.c"),
            append(prefix, "zstd/lib/common/fse_decompress.c"),
            append(prefix, "zstd/lib/common/xxhash.c"),
        }, &[_][]const u8{});

        // Add x86_64-specific assembly if possible
        const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
        if (arch.isX86()) {
            exe.addAssemblyFile(.{
                .path = append(prefix, "zstd/lib/decompress/huf_decompress_amd64.S"),
            });
        }
    }

    // Add squashfuse source files
    exe.addIncludePath(.{ .path = append(prefix, "squashfuse") });
    exe.addCSourceFiles(&[_][]const u8{
        append(prefix, "squashfuse/fs.c"),
        append(prefix, "squashfuse/table.c"),
        append(prefix, "squashfuse/xattr.c"),
        append(prefix, "squashfuse/cache.c"),
        append(prefix, "squashfuse/dir.c"),
        append(prefix, "squashfuse/file.c"),
        append(prefix, "squashfuse/nonstd-makedev.c"),
        append(prefix, "squashfuse/nonstd-pread.c"),
        append(prefix, "squashfuse/nonstd-stat.c"),
        append(prefix, "squashfuse/stat.c"),
        append(prefix, "squashfuse/stack.c"),
        append(prefix, "squashfuse/swap.c"),
    }, &[_][]const u8{});

    exe.linkLibC();
}
