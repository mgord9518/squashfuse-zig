const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const LibDecodeFn = fn (
    [*]const u8,
    [*]u8,
    c_int,
    c_int,
) callconv(.C) c_int;

pub const lib_decode_name = "LZ4_decompress_safe";

// Initialized in `compression.zig`
pub var lib_decode: *const LibDecodeFn = undefined;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    const ret = lib_decode(
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
