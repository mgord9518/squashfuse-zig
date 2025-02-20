const std = @import("std");
const lz4 = @import("lz4");
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

    var read: usize = 0;
    var written: usize = 0;

    lz4.block.decodeBlock(in, &read, out, &written) catch |err| {
        return switch (err) {
            error.IncompleteData, error.NoEnoughData => error.EndOfStream,
        };
    };

    return written;
}
