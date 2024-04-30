const std = @import("std");
const squashfuse = @import("../root.zig");
const DecompressError = squashfuse.DecompressError;

extern fn ZSTD_isError(usize) bool;
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

    if (ZSTD_isError(ret)) {
        return DecompressError.Error;
    }

    return ret;
}
