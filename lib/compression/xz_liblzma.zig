const std = @import("std");
const io = std.io;
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const lib_decode_name = "lzma_stream_buffer_decode";

// Initialized in `compression.zig`
pub var lib_decode: *const LibDecodeFn = undefined;

pub const LibDecodeFn = fn (
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
) callconv(.C) c_int;

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    var memlimit: u64 = 0xffff_ffff_ffff_ffff;

    var inpos: usize = 0;
    var outpos: usize = 0;

    const err = lib_decode(
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

    return switch (err) {
        // Errno 2 is `LZMA_NO_CHECK`, which is only a warning according to
        // LZMA docs
        0, 2 => outpos,

        1 => error.EndOfStream,
        5 => error.OutOfMemory,
        6 => error.NoSpaceLeft,
        7, 9 => error.CorruptInput,

        else => error.Error,
    };
}
