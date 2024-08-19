const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const LibDecodeFn = fn (
    [*]u8,
    usize,
    [*]const u8,
    usize,
) callconv(.C) usize;

pub const lib_decode_name = "ZSTD_decompress";

// Initialized in `compression.zig`
pub var lib_decode: *const LibDecodeFn = undefined;

extern fn ZSTD_getErrorCode(usize) usize;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    const ret = lib_decode(
        out.ptr,
        out.len,
        in.ptr,
        in.len,
    );

    return switch (ZSTD_getErrorCode(ret)) {
        0 => ret,

        20 => error.CorruptInput,
        22 => error.WrongChecksum,
        64 => error.OutOfMemory,
        70 => error.NoSpaceLeft,

        else => error.Error,
    };
}
