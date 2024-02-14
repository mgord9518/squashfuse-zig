const std = @import("std");
const builtin = std.builtin;

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

pub const lz4Decode = if (build_options.enable_lz4) @import("algos/lz4_liblz4.zig").lz4Decode else {};
pub const lzoDecode = if (build_options.enable_lzo) @import("algos/lzo_minilzo.zig").lzoDecode else {};
pub const zlibDecode = if (build_options.enable_zlib) @import("algos/zlib_libdeflate.zig").zlibDecode else {};

// TODO: auto-generate these with comptime

//pub usingnamespace if (build_options.enable_zstd) @Type(.{ .Struct = .{
//    .layout = .Auto,
//    .fields = &.{
//        .{
//            .name = "zig_zstd_decode",
//            .type = fn ([*]u8, usize, [*]u8, *usize) callconv(.C) c.sqfs_err,
//            .is_comptime = false,
//            .alignment = @alignOf(*anyopaque),
//            .default_value = null,
//        },
//    },
//    .decls = &.{},
//    .is_tuple = false,
//} }) else struct {};

pub usingnamespace if (build_options.enable_zstd) struct {
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
} else struct {};

pub usingnamespace if (build_options.enable_xz) struct {
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
} else struct {};

pub usingnamespace if (build_options.enable_zlib) struct {
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
} else struct {};

pub usingnamespace if (build_options.enable_lzo) struct {
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
} else struct {};

pub usingnamespace if (build_options.enable_lz4) struct {
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
} else struct {};
