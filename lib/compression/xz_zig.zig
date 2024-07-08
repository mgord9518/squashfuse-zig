const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub fn decode(
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

    return decompressor.read(out) catch |err| {
        return switch (err) {
            error.CorruptInput => error.CorruptInput,
            error.EndOfStream => error.EndOfStream,
            error.WrongChecksum => error.WrongChecksum,

            else => error.Error,
        };
    };
}
