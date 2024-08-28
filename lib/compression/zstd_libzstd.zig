const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const required_symbols = struct {
    pub var ZSTD_decompress: *const fn (
        [*]u8,
        usize,
        [*]const u8,
        usize,
    ) callconv(.C) usize = undefined;

    pub var ZSTD_getErrorCode: *const fn (
        usize,
    ) callconv(.C) usize = undefined;
};

pub fn init(allocator: std.mem.Allocator) *anyopaque {
    _ = allocator;
    return undefined;
}

pub fn deinit(ptr: *anyopaque) void {
    _ = ptr;
}

pub fn decompressBlock(
    decompressor: *anyopaque,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = decompressor;

    const ret = required_symbols.ZSTD_decompress(
        out.ptr,
        out.len,
        in.ptr,
        in.len,
    );

    return switch (required_symbols.ZSTD_getErrorCode(ret)) {
        0 => ret,

        20 => error.CorruptInput,
        22 => error.WrongChecksum,
        64 => error.OutOfMemory,
        70 => error.NoSpaceLeft,

        else => error.Error,
    };
}
