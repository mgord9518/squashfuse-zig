const std = @import("std");
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;
const xz = std.compress.xz;

// Expose a C function to utilize Zig's stdlib XZ implementation
export fn zig_xz_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) usize {
    var stream = std.io.fixedBufferStream(in[0..in_size]);

    var allocator = std.heap.c_allocator;

    var decompressor = xz.decompress(
        allocator,
        stream.reader(),
    ) catch return 1;

    defer decompressor.deinit();

    var buf = out[0..out_size.*];

    out_size.* = decompressor.read(buf) catch return 2;

    return 0;
}
