const std = @import("std");
const compression = @import("../compression.zig");
const DecompressError = compression.DecompressError;

pub const required_symbols = struct {
    pub var uncompress: *const fn (
        [*]u8,
        *c_ulong,
        [*]const u8,
        c_ulong,
    ) callconv(.C) c_int = undefined;
};

pub fn decode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;

    var written: c_ulong = @intCast(out.len);

    const err = required_symbols.uncompress(
        out.ptr,
        &written,
        in.ptr,
        in.len,
    );

    // TODO: audit these and ensure they're correct
    if (err < 0) return switch (err) {
        // Z_STREAM_ERROR
        -2 => DecompressError.ShortOutput,

        // Z_DATA_ERROR
        -3 => DecompressError.CorruptInput,

        // Z_MEM_ERROR
        -4 => DecompressError.OutOfMemory,

        // Z_BUF_ERROR
        -5 => DecompressError.NoSpaceLeft,

        // Z_ERRNO, Z_VERSION_ERROR
        -1, -6 => DecompressError.Error,

        else => DecompressError.Error,
    };

    return written;
}
