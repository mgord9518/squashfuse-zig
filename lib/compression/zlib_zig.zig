const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

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

    var stream = std.io.fixedBufferStream(in);

    // TODO
    var decomp = std.compress.zlib.decompressor(
        stream.reader(),
    );

    return decomp.reader().readAll(out) catch return error.CorruptInput;
}
