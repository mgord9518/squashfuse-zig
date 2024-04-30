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
            if (comptime builtWithDecompression(.zlib)) {
                if (build_options.@"use-zig-zlib") {
                    return @import("algos/zlib_zig.zig").decode;
                }

                return @import("algos/zlib_libdeflate.zig").decode;
            }
        },
        // TODO
        .lzma => return error.InvalidCompression,
        .xz => {
            if (comptime builtWithDecompression(.xz)) {
                if (build_options.@"use-zig-xz") {
                    return @import("algos/xz_zig.zig").decode;
                }

                return @import("algos/xz_liblzma.zig").decode;
            }
        },
        .lzo => {
            if (comptime builtWithDecompression(.lzo)) {
                return @import("algos/lzo_minilzo.zig").decode;
            }
        },
        .lz4 => {
            if (comptime builtWithDecompression(.lz4)) {
                return @import("algos/lz4_liblz4.zig").decode;
            }
        },
        .zstd => {
            if (comptime builtWithDecompression(.zstd)) {
                if (!build_options.@"use-zig-zstd") {
                    return @import("algos/zstd_zig.zig").decode;
                }

                return @import("algos/zstd_libzstd.zig").decode;
            }
        },
    }

    return error.InvalidCompression;
}
