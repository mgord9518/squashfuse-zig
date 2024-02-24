const std = @import("std");
const squashfuse = @import("../squashfuse.zig");
const DecompressError = squashfuse.DecompressError;

pub fn zstdDecode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    var stream = std.io.fixedBufferStream(in);

    var decompressor = std.zstd.decompressStream(
        allocator,
        stream.reader(),
    );

    defer decompressor.deinit();

    return decompressor.read(out) catch return error.Error;
}
