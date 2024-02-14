pub const Algos = @This();

const std = @import("std");
const builtin = std.builtin;
const build_options = @import("build_options");
const squashfuse = @import("SquashFs.zig");
const SquashFs = squashfuse.SquashFs;

const c = @cImport({
    @cInclude("squashfuse.h");
});

pub const LibsquashfuseDecompressor = *const fn ([*]const u8, usize, [*]u8, *usize) callconv(.C) c.sqfs_err;

pub fn getLibsquashfuseDecompressionFn(comptime compression: SquashFs.Compression) ?LibsquashfuseDecompressor {
    if (!comptime builtWithDecompression(compression)) {
        return null;
    }

    return struct {
        pub fn decompressBlock(
            in: [*]const u8,
            in_size: usize,
            out: [*]u8,
            out_size: *usize,
        ) callconv(.C) c.sqfs_err {
            const allocator = std.heap.c_allocator;

            out_size.* = @field(Algos, @tagName(compression) ++ "Decode")(
                allocator,
                in[0..in_size],
                out[0..out_size.*],
            ) catch return c.SQFS_ERR;

            return c.SQFS_OK;
        }
    }.decompressBlock;
}

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
