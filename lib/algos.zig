const std = @import("std");

const c = @cImport({
    @cInclude("squashfuse.h");
});

const build_options = @import("build_options");

const allocator = std.heap.c_allocator;

pub const xzDecode = if (build_options.enable_xz)
blk: {
    if (build_options.use_zig_xz) {
        break :blk @import("algos/xz_zig.zig").xzDecode;
    } else {
        break :blk @import("algos/xz_liblzma.zig").xzDecode;
    }
} else struct {};

pub const zstdDecode = if (build_options.enable_zstd)
blk: {
    if (build_options.use_zig_zstd) {
        break :blk @import("algos/zstd_zig.zig").zstdDecode;
    } else {
        break :blk @import("algos/zstd_libzstd.zig").zstdDecode;
    }
} else struct {};

pub const lz4Decode = @import("algos/lz4_liblz4.zig").lz4Decode;
pub const lzoDecode = @import("algos/lzo_minilzo.zig").lzoDecode;
pub const zlibDecode = @import("algos/zlib_libdeflate.zig").zlibDecode;

// TODO: auto-generate these with comptime
pub export fn zig_zstd_decode(
    in: [*]u8,
    in_size: usize,
    out: [*]u8,
    out_size: *usize,
) callconv(.C) c.sqfs_err {
    out_size.* = zstdDecode(
        allocator,
        in[0..in_size],
        out[0..out_size.*],
    ) catch return c.SQFS_ERR;

    return c.SQFS_OK;
}

pub export fn zig_xz_decode(
    in: [*]u8,
    in_size: usize,
    out: [*]u8,
    out_size: *usize,
) callconv(.C) c.sqfs_err {
    out_size.* = xzDecode(
        allocator,
        in[0..in_size],
        out[0..out_size.*],
    ) catch return c.SQFS_ERR;

    return c.SQFS_OK;
}

pub export fn zig_zlib_decode(
    in: [*]u8,
    in_size: usize,
    out: [*]u8,
    out_size: *usize,
) callconv(.C) c.sqfs_err {
    out_size.* = zlibDecode(
        allocator,
        in[0..in_size],
        out[0..out_size.*],
    ) catch return c.SQFS_ERR;

    return c.SQFS_OK;
}

pub export fn zig_lzo_decode(
    in: [*]u8,
    in_size: usize,
    out: [*]u8,
    out_size: *usize,
) callconv(.C) c.sqfs_err {
    out_size.* = lzoDecode(
        allocator,
        in[0..in_size],
        out[0..out_size.*],
    ) catch return c.SQFS_ERR;

    return c.SQFS_OK;
}

pub export fn zig_lz4_decode(
    in: [*]u8,
    in_size: usize,
    out: [*]u8,
    out_size: *usize,
) callconv(.C) c.sqfs_err {
    out_size.* = lz4Decode(
        allocator,
        in[0..in_size],
        out[0..out_size.*],
    ) catch return c.SQFS_ERR;

    return c.SQFS_OK;
}
