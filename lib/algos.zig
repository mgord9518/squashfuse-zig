pub const Algos = @This();

const std = @import("std");
const builtin = std.builtin;
const build_options = @import("build_options");
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const SquashFsError = squashfuse.SquashFsError;

pub fn builtWithDecompression(comptime compression: SquashFs.Compression) bool {
    return @field(build_options, "enable-" ++ @tagName(compression));
}

pub fn getDecompressor(kind: SquashFs.Compression) SquashFsError!SquashFs.Decompressor {
    switch (kind) {
        .zlib => {
            if (!builtWithDecompression(.zlib)) return error.InvalidCompression;

            return @import("algos/zlib_libdeflate.zig").decode;
        },
        // TODO
        .lzma => return error.InvalidCompression,
        .xz => {
            if (!builtWithDecompression(.xz)) return error.InvalidCompression;

            if (build_options.@"use-zig-xz") {
                return @import("algos/xz_zig.zig").decode;
            }

            return @import("algos/xz_liblzma.zig").decode;
        },
        .lzo => {
            if (!builtWithDecompression(.lzo)) return error.InvalidCompression;

            return @import("algos/lzo_minilzo.zig").decode;
        },
        .lz4 => {
            if (!builtWithDecompression(.lz4)) return error.InvalidCompression;

            return @import("algos/lz4_liblz4.zig").decode;
        },
        .zstd => {
            if (!builtWithDecompression(.zstd)) return error.InvalidCompression;

            if (build_options.@"use-zig-zstd") {
                return @import("algos/zstd_zig.zig").decode;
            }

            return @import("algos/zstd_libzstd.zig").decode;
        },
    }

    unreachable;
}
