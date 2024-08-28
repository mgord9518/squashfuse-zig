const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

const Self = @This();

allocator: std.mem.Allocator,
window_buffer: []u8,

pub fn init(allocator: std.mem.Allocator) *anyopaque {
    const ptr = allocator.create(Self) catch unreachable;

    ptr.* = .{
        .allocator = allocator,
        .window_buffer = allocator.alloc(
            u8,
            std.compress.zstd.DecompressorOptions.default_window_buffer_len,
        ) catch unreachable,
    };

    return ptr;
}

pub fn deinit(ptr: *anyopaque) void {
    const decompressor: *Self = @ptrCast(@alignCast(ptr));

    decompressor.allocator.free(decompressor.window_buffer);
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
    var decomp = std.compress.zstd.decompressor(
        stream.reader(),
        .{ .window_buffer = decompressor.window_buffer },
    );

    return decomp.reader().readAll(out) catch return error.Error;
}
