const std = @import("std");
const squashfuse = @import("../SquashFs.zig");
const DecompressError = squashfuse.DecompressError;

pub fn xzDecode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    var stream = std.io.fixedBufferStream(in);

    var decompressor = std.compress.xz.decompress(
        allocator,
        stream.reader(),
    ) catch return error.Error;

    defer decompressor.deinit();

    return decompressor.read(out) catch return error.Error;
}
