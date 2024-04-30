const std = @import("std");
const squashfuse = @import("../root.zig");
const DecompressError = squashfuse.DecompressError;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    var stream = std.io.fixedBufferStream(in);

    var decompressor = std.compress.zlib.decompressor(
        stream.reader(),
    );

    return decompressor.read(out) catch return error.BadData;
}
