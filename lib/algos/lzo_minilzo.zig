const std = @import("std");
const squashfuse = @import("../SquashFs.zig");
const DecompressError = squashfuse.DecompressError;

extern fn lzo1x_decompress_safe(
    [*]const u8,
    u32,
    [*]u8,
    *u32,
    ?*anyopaque,
) u32;

pub fn lzoDecode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;
    var out_size = out.len;

    const err = lzo1x_decompress_safe(
        in.ptr,
        @intCast(in.len),
        out.ptr,
        @ptrCast(&out_size),
        null,
    );

    if (err != 0) {
        return error.Error;
    }

    return out_size;
}
