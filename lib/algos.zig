pub const Algos = @This();

const std = @import("std");
const builtin = std.builtin;
const build_options = @import("build_options");
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;

pub fn builtWithDecompression(comptime compression: SquashFs.Compression) bool {
    return switch (compression) {
        .zlib => build_options.enable_zlib,
        .lzma => false,
        .lzo => build_options.enable_lzo,
        .xz => build_options.enable_xz,
        .lz4 => build_options.enable_lz4,
        .zstd => build_options.enable_zstd,
    };
}

pub const zlibDecode = if (build_options.enable_zlib) @import("algos/zlib_libdeflate.zig").zlibDecode else {};

// TODO: lzma

pub const lzoDecode = if (build_options.enable_lzo) @import("algos/lzo_minilzo.zig").lzoDecode else {};

pub const xzDecode = if (build_options.enable_xz)
blk: {
    if (build_options.use_zig_xz) {
        break :blk @import("algos/xz_zig.zig").xzDecode;
    } else {
        break :blk @import("algos/xz_liblzma.zig").xzDecode;
    }
} else struct {};

pub const lz4Decode = if (build_options.enable_lz4) @import("algos/lz4_liblz4.zig").lz4Decode else {};

pub const zstdDecode = if (build_options.enable_zstd)
blk: {
    if (build_options.use_zig_zstd) {
        break :blk @import("algos/zstd_zig.zig").zstdDecode;
    } else {
        break :blk @import("algos/zstd_libzstd.zig").zstdDecode;
    }
} else struct {};
