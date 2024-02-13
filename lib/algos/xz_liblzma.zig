const std = @import("std");
const io = std.io;
const squashfuse = @import("../SquashFs.zig");
const DecompressError = squashfuse.DecompressError;

extern fn lzma_stream_buffer_decode(
    memlemit: *u64,
    flags: u32,
    // TODO: set allocator
    allocator: ?*anyopaque,
    in: [*]const u8,
    in_pos: *usize,
    in_size: usize,
    out: [*]u8,
    out_pos: *usize,
    out_size: usize,
) c_int;

pub fn xzDecode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    var memlimit: u64 = 0xffff_ffff_ffff_ffff;

    var inpos: usize = 0;
    var outpos: usize = 0;

    const err = lzma_stream_buffer_decode(
        &memlimit,
        0,
        null,
        in.ptr,
        &inpos,
        in.len,
        out.ptr,
        &outpos,
        out.len,
    );

    if (err != 0) {
        return error.Error;
    }

    return outpos;
}
