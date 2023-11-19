const std = @import("std");
const builtin = @import("builtin");

fn initExecutable(b: *std.build.Builder, name: []const u8) !*std.Build.Step.Compile {
    const path = try std.fmt.allocPrint(
        b.allocator,
        "src/{s}.zig",
        .{name},
    );
    defer b.allocator.free(path);

    return b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = path },
    });
}

pub fn build(b: *std.build.Builder) !void {
    const allocator = b.allocator;

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

    const enable_lzo = b.option(
        bool,
        "enable-lzo",
        "enable lzo decompression (default: true)",
    ) orelse true;

    const build_squashfuse = b.option(
        bool,
        "build-squashfuse",
        "whether or not to build main squashfuse executable (default: true)",
    ) orelse true;

    const build_squashfuse_tool = b.option(
        bool,
        "build-squashfuse_tool",
        "whether or not to build FUSEless squashfuse_tool executable (default: true)",
    ) orelse true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const executable_names = &[_]?[]const u8{
        if (build_squashfuse) "squashfuse" else null,
        if (build_squashfuse_tool) "squashfuse_tool" else null,
    };

    var executable_list = std.ArrayList(*std.Build.Step.Compile).init(allocator);
    for (executable_names) |executable| {
        if (executable) |name| {
            try executable_list.append(try initExecutable(b, name));
        }
    }

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_xz", enable_xz);
    exe_options.addOption(bool, "enable_zlib", enable_zlib);
    exe_options.addOption(bool, "use_libdeflate", use_libdeflate);
    exe_options.addOption(bool, "enable_lzo", enable_lzo);
    exe_options.addOption(bool, "enable_lz4", enable_lz4);
    exe_options.addOption(bool, "enable_zstd", enable_zstd);
    exe_options.addOption(bool, "use_zig_zstd", use_zig_zstd);
    exe_options.addOption(bool, "use_zig_xz", true);

    const squashfuse_module = b.addModule("squashfuse", .{
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

    for (executable_list.items) |exe| {
        exe.target = target;
        exe.optimize = optimize;
        exe.strip = strip;

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
            .{ .source_file = fuse_dep.module("fuse").source_file },
        );

        const clap_module = b.addModule("clap", .{
            .source_file = clap_dep.path("clap.zig"),
        });

        link(exe, .{
            .enable_lz4 = enable_lz4,
            .enable_lzo = enable_lzo,
            .enable_zlib = enable_zlib,
            .enable_zstd = enable_zstd,
            .enable_xz = enable_xz,

            .enable_fuse = std.mem.eql(u8, exe.name, "squashfuse"),
            .use_system_fuse = use_system_fuse,

            .use_libdeflate = use_libdeflate,
        });

        exe.addModule("squashfuse", squashfuse_module);
        exe.addModule("fuse", fuse_module);
        exe.addModule("clap", clap_module);

        b.installArtifact(exe);
    }

    // TODO: create symlinks in install directory
    //    if (build_squashfuse_tool) {
    //        const cwd = std.fs.cwd();
    //
    //        cwd.symLink("squashfuse_tool", "zig-out/bin/squashfuse_ls", .{}) catch {};
    //        cwd.symLink("squashfuse_tool", "zig-out/bin/squashfuse_extract", .{}) catch {};
    //    }

    const run_cmd = b.addRunArtifact(executable_list.items[0]);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "lib/test.zig" },
        .target = executable_list.items[0].target,
        .optimize = executable_list.items[0].optimize,
    });

    link(unit_tests, .{
        .enable_lz4 = true,
        .enable_lzo = true,
        .enable_zlib = true,
        .enable_zstd = true,
        .enable_xz = true,

        // TODO: test with libdeflate disabled
        .use_libdeflate = true,
    });

    const test_options = b.addOptions();
    test_options.addOption(bool, "enable_xz", true);
    test_options.addOption(bool, "enable_zlib", true);
    test_options.addOption(bool, "use_libdeflate", true);
    test_options.addOption(bool, "enable_lzo", true);
    test_options.addOption(bool, "enable_lz4", true);
    test_options.addOption(bool, "enable_zstd", true);
    test_options.addOption(bool, "use_zig_zstd", false);
    test_options.addOption(bool, "use_zig_xz", true);

    const squashfuse_test_module = b.addModule("squashfuse", .{
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

    unit_tests.addModule("squashfuse", squashfuse_test_module);

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

    use_zig_xz: bool = true,

    use_system_fuse: bool = false,
    use_libdeflate: bool = true,

    fusermount_dir: []const u8 = "/usr/local/bin",
};

pub fn module(b: *std.Build, opts: LinkOptions) *std.Build.Module {
    const lib_options = b.addOptions();
    lib_options.addOption(bool, "enable_xz", opts.enable_xz);
    lib_options.addOption(bool, "enable_zlib", opts.enable_zlib);
    lib_options.addOption(bool, "use_libdeflate", opts.use_libdeflate);
    lib_options.addOption(bool, "enable_lzo", opts.enable_lzo);
    lib_options.addOption(bool, "enable_lz4", opts.enable_lz4);
    lib_options.addOption(bool, "enable_zstd", opts.enable_zstd);
    //    lib_options.addOption(bool, "use_zig_zstd", opts.use_zig_zstd);

    return b.createModule(.{
        .source_file = .{ .path = b.pathFromRoot("lib.zig") },
        .dependencies = &.{
            .{
                .name = "build_options",
                .module = lib_options.createModule(),
            },
        },
    });
}

pub fn link(exe: *std.Build.Step.Compile, opts: LinkOptions) void {
    const b = exe.step.owner;

    if (opts.enable_fuse) {
        if (opts.use_system_fuse) {
            exe.linkSystemLibrary("fuse3");
        } else {
            const fuse_dep = exe.step.owner.dependency("fuse", .{
                .target = exe.target,
                .optimize = exe.optimize,
            });

            exe.linkLibrary(fuse_dep.artifact("fuse"));
        }
    }

    if (opts.enable_zlib) {
        if (opts.use_libdeflate) {
            const libdeflate_dep = exe.step.owner.dependency("libdeflate", .{
                .target = exe.target,
                .optimize = exe.optimize,
            });

            exe.addIncludePath(libdeflate_dep.path("."));

            // TODO: is there a better way to do this?
            const c_files = &[_][]const u8{
                "lib/adler32.c",
                "lib/crc32.c",
                "lib/deflate_decompress.c",
                "lib/utils.c",
                "lib/zlib_decompress.c",
            };

            for (c_files) |c_file| {
                exe.addCSourceFile(.{
                    .file = libdeflate_dep.path(c_file),
                    .flags = &[_][]const u8{},
                });
            }

            const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
            if (arch.isX86()) {
                exe.addCSourceFile(.{
                    .file = libdeflate_dep.path("lib/x86/cpu_features.c"),
                    .flags = &[_][]const u8{},
                });
            } else if (arch.isARM() or arch.isAARCH64()) {
                exe.addCSourceFile(.{
                    .file = libdeflate_dep.path("lib/arm/cpu_features.c"),
                    .flags = &[_][]const u8{},
                });
            }
        } else {
            // TODO: maybe vendor zlib? Idk, I don't see the benefit. Anyone
            // I imagine anyone specifically choosing zlib probably wants it
            // as it's a system library on essentially every Linux distro ever
            // created
            exe.linkSystemLibrary("zlib");
        }
    }

    if (opts.enable_lz4) {
        const liblz4_dep = exe.step.owner.dependency("liblz4", .{
            .target = exe.target,
            .optimize = exe.optimize,
        });

        exe.addIncludePath(liblz4_dep.path("lib"));

        exe.addCSourceFile(.{
            .file = liblz4_dep.path("lib/lz4.c"),
            .flags = &[_][]const u8{},
        });
    }

    if (opts.enable_lzo) {
        const liblzo_dep = exe.step.owner.dependency("libminilzo", .{
            .target = exe.target,
            .optimize = exe.optimize,
        });

        exe.addIncludePath(liblzo_dep.path("."));

        exe.addCSourceFile(.{
            .file = liblzo_dep.path("minilzo.c"),
            .flags = &[_][]const u8{},
        });
    }

    // TODO: vendor XZ correctly
    //    if (opts.enable_xz and !opts.use_zig_xz) {
    //        const libxz_dep = exe.step.owner.dependency("libxz", .{
    //            .target = exe.target,
    //            .optimize = exe.optimize,
    //        });
    //
    //        exe.addIncludePath(libxz_dep.path("src/liblzma/api"));
    //        exe.addIncludePath(libxz_dep.path("src/liblzma/lz"));
    //        exe.addIncludePath(libxz_dep.path("src/common"));
    //        exe.addIncludePath(libxz_dep.path("src/liblzma/common"));
    //        exe.addIncludePath(libxz_dep.path("src/liblzma/check"));
    //
    //        exe.defineCMacro("HAVE_STDBOOL_H", "1");
    //
    //        const c_files = &[_][]const u8{
    //            "src/liblzma/lzma/lzma2_decoder.c",
    //            "src/liblzma/lz/lz_decoder.c",
    //
    //            "src/liblzma/common/stream_buffer_decoder.c",
    //            "src/liblzma/common/stream_decoder.c",
    //            "src/liblzma/common/common.c",
    //            "src/liblzma/common/index_hash.c",
    //            "src/liblzma/common/stream_flags_common.c",
    //            "src/liblzma/check/crc32_fast.c",
    //            "src/liblzma/check/crc32_small.c",
    //            "src/liblzma/check/check.c",
    //            "src/liblzma/common/block_decoder.c",
    //        };
    //
    //        for (c_files) |c_file| {
    //            exe.addCSourceFile(.{
    //                .file = libxz_dep.path(c_file),
    //                .flags = &[_][]const u8{},
    //            });
    //        }
    //    }

    if (opts.enable_zstd) {
        const libzstd_dep = exe.step.owner.dependency("libzstd", .{
            .target = exe.target,
            .optimize = exe.optimize,
        });

        exe.addIncludePath(libzstd_dep.path("lib"));

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
            exe.addCSourceFile(.{
                .file = libzstd_dep.path(c_file),
                .flags = &[_][]const u8{},
            });
        }

        // Add x86_64-specific assembly if possible
        const arch = exe.target.cpu_arch orelse builtin.cpu.arch;
        if (arch.isX86()) {
            // TODO: LazyPath for `addAssemblyFile`?
            // Calling `addCSourceFile` instead works, but is obviously suboptimal
            exe.addCSourceFile(.{
                .file = libzstd_dep.path("lib/decompress/huf_decompress_amd64.S"),
                .flags = &[_][]const u8{},
            });
        }
    }

    const os_tag = exe.target.os_tag orelse builtin.os.tag;

    const libsquashfuse_dep = exe.step.owner.dependency("libsquashfuse", .{
        .target = exe.target,
        .optimize = exe.optimize,
    });

    exe.addIncludePath(libsquashfuse_dep.path("."));
    exe.addIncludePath(.{ .path = b.pathFromRoot("squashfuse_config") });

    // TODO: Support other OSes besides Linux
    switch (os_tag) {
        .linux => {
            exe.defineCMacro("HAVE_LINUX_TYPES_LE16", "1");
        },
        .windows => {
            exe.addIncludePath(libsquashfuse_dep.path("win"));
        },
        else => {},
    }

    exe.defineCMacro("FUSE_USE_VERSION", "32");
    exe.defineCMacro("HAVE_ASM_BYTEORDER", "1");
    exe.defineCMacro("HAVE_DECL_FUSE_ADD_DIRENTRY", "1");
    exe.defineCMacro("HAVE_DECL_FUSE_DAEMONIZE", "1");
    exe.defineCMacro("HAVE_DLFCN", "1");
    exe.defineCMacro("HAVE_ENDIAN_H", "1");
    exe.defineCMacro("HAVE_INTTYPES_H", "1");
    exe.defineCMacro("HAVE_LIBPTHREAD", "1");
    exe.defineCMacro("HAVE_STDINT_H", "1");
    exe.defineCMacro("HAVE_STDIO_H", "1");
    exe.defineCMacro("HAVE_STDLIB_H", "1");
    exe.defineCMacro("HAVE_STRINGS_H", "1");
    exe.defineCMacro("HAVE_STRING_H", "1");
    exe.defineCMacro("HAVE_SYS_SYSMACROS_H", "1");
    exe.defineCMacro("HAVE_SYS_TYPES_H", "1");
    exe.defineCMacro("SQFS_MULTITHREADED", "1");

    // Add squashfuse source files
    const c_files = &[_][]const u8{
        "fs.c",
        "table.c",
        "xattr.c",
        "cache.c",
        "cache_mt.c",
        "dir.c",
        "file.c",
        "nonstd-makedev.c",
        "nonstd-pread.c",
        "nonstd-stat.c",
        "stat.c",
        "stack.c",
        "swap.c",
    };

    for (c_files) |c_file| {
        exe.addCSourceFile(.{
            .file = libsquashfuse_dep.path(c_file),
            .flags = &[_][]const u8{},
        });
    }

    exe.linkLibC();
}
