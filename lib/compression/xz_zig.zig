const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

const Self = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) *anyopaque {
    const ptr = allocator.create(Self) catch unreachable;

    ptr.* = .{
        .allocator = allocator,
    };

    return ptr;
}

pub fn deinit(ptr: *anyopaque) void {
    const decompressor: *Self = @ptrCast(@alignCast(ptr));

    decompressor.allocator.destroy(decompressor);
}

pub fn decompressBlock(
    ptr: *anyopaque,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    const decompressor: *Self = @ptrCast(@alignCast(ptr));

    var stream = std.io.fixedBufferStream(in);

    // TODO
    var decomp = std.compress.xz.decompress(
        decompressor.allocator,
        stream.reader(),
    ) catch return error.Error;

    defer decomp.deinit();

    return decomp.reader().readAll(out) catch |err| {
        return switch (err) {
            error.CorruptInput => error.CorruptInput,
            error.EndOfStream => error.EndOfStream,
            error.WrongChecksum => error.WrongChecksum,

            else => error.Error,
        };
    };
}
