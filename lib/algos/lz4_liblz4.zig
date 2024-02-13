const std = @import("std");
const squashfuse = @import("../SquashFs.zig");
const DecompressError = squashfuse.DecompressError;

extern fn LZ4_decompress_safe(
    [*]const u8,
    [*]u8,
    c_int,
    c_int,
) c_int;

pub fn lz4Decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    const ret = LZ4_decompress_safe(
        in.ptr,
        out.ptr,
        @intCast(in.len),
        @intCast(out.len),
    );

    if (ret < 0) {
        return error.Error;
    }

    return @intCast(ret);
}
