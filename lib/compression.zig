pub const Compression = @This();

const std = @import("std");
const squashfuse = @import("root.zig");
const build_options = squashfuse.build_options;
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
                    return @import("compression/zlib_zig.zig").decode;
                }

                return @import("compression/zlib_libdeflate.zig").decode;
            }
        },
        // TODO
        .lzma => return error.InvalidCompression,
        .xz => {
            if (comptime builtWithDecompression(.xz)) {
                if (build_options.@"use-zig-xz") {
                    return @import("compression/xz_zig.zig").decode;
                }

                return @import("compression/xz_liblzma.zig").decode;
            }
        },
        .lzo => {
            if (comptime builtWithDecompression(.lzo)) {
                return @import("compression/lzo_minilzo.zig").decode;
            }
        },
        .lz4 => {
            if (comptime builtWithDecompression(.lz4)) {
                return @import("compression/lz4_liblz4.zig").decode;
            }
        },
        .zstd => {
            if (comptime builtWithDecompression(.zstd)) {
                if (build_options.@"use-zig-zstd") {
                    return @import("compression/zstd_zig.zig").decode;
                }

                return @import("compression/zstd_libzstd.zig").decode;
            }
        },
    }

    return error.InvalidCompression;
}
