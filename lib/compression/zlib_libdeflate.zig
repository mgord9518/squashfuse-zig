const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

const Self = @This();

allocator: std.mem.Allocator,
internal_decompressor: LibdeflateDecompressor,

pub const required_symbols = struct {
    pub var libdeflate_zlib_decompress: *const fn (
        *anyopaque,
        [*]const u8,
        usize,
        [*]u8,
        usize,
        *usize,
    ) callconv(.C) c_int = undefined;
};

pub fn init(allocator: std.mem.Allocator) *anyopaque {
    const ptr = allocator.create(Self) catch unreachable;

    ptr.* = .{
        .allocator = allocator,
        .internal_decompressor = LibdeflateDecompressor{},
    };

    return ptr;
}

pub fn deinit(ptr: *anyopaque) void {
    const decompressor: *Self = @ptrCast(@alignCast(ptr));

    decompressor.allocator.destroy(decompressor);
}

pub fn decompressBlock(
    ptr: *anyopaque,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    const decompressor: *Self = @ptrCast(@alignCast(ptr));

    var written: usize = undefined;

    const err = required_symbols.libdeflate_zlib_decompress(
        &decompressor.internal_decompressor,
        in.ptr,
        in.len,
        out.ptr,
        out.len,
        &written,
    );

    return switch (err) {
        // Defined in <https://github.com/ebiggers/libdeflate/blob/master/libdeflate.h>
        0 => written,

        1 => DecompressError.CorruptInput,
        2 => DecompressError.ShortOutput,
        3 => DecompressError.NoSpaceLeft,
        else => DecompressError.Error,
    };
}

// Deflate constants
const litlen_syms = 288;
const offset_syms = 32;
const max_lens_overrun = 137;
const max_num_syms = 288;
const precode_syms = 19;

// LibDeflate constants
const precode_enough = 128;
const litlen_enough = 2342;
const offset_enough = 402;

const LibdeflateDecompressor = extern struct {
    _: extern union {
        precode_lens: [precode_syms]u8,

        _: extern struct {
            lens: [litlen_syms + offset_syms + max_lens_overrun]u8,
            precode_table: [precode_enough]u32,
        },

        litlen_decode_table: [litlen_enough]u32,
    } = undefined,

    offset_decode_table: [offset_enough]u32 = undefined,
    sorted_syms: [max_num_syms]u16 = undefined,
    static_codes_loaded: bool = false,
    litlen_tablebits: u32 = undefined,
    free_func: ?*anyopaque = undefined,
};
