const std = @import("std");
const squashfuse = @import("../squashfuse.zig");
const DecompressError = squashfuse.DecompressError;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    const window_buffer = try allocator.alloc(
        u8,
        std.compress.zstd.DecompressorOptions.default_window_buffer_len,
    );
    defer allocator.free(window_buffer);

    var stream = std.io.fixedBufferStream(in);

    var decompressor = std.compress.zstd.decompressor(
        stream.reader(),
        .{ .window_buffer = window_buffer },
    );

    return decompressor.read(out) catch return error.Error;
}
