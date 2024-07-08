const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

extern fn ZSTD_getErrorCode(usize) usize;
extern fn ZSTD_decompress(
    [*]u8,
    usize,
    [*]const u8,
    usize,
) usize;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    const ret = ZSTD_decompress(
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
