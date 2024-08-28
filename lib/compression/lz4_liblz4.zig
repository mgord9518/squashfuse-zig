const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const required_symbols = struct {
    pub var LZ4_decompress_safe: *const fn (
        [*]const u8,
        [*]u8,
        c_int,
        c_int,
    ) callconv(.C) c_int = undefined;
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

    const ret = required_symbols.LZ4_decompress_safe(
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
