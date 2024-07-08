const std = @import("std");
const squashfuse = @import("root.zig");
const build_options = squashfuse.build_options;
const SquashFs = squashfuse.SquashFs;
const SquashFsError = squashfuse.SquashFsError;

pub const DecompressError = error{
    Error,
    CorruptInput,
    WrongChecksum,
    NoSpaceLeft,
    EndOfStream,
    // TODO: rename these to zig stdlib conventions
    ShortOutput,
    OutOfMemory,
};

pub const Compression = enum(u16) {
    zlib = 1,
    lzma = 2,
    lzo = 3,
    xz = 4,
    lz4 = 5,
    zstd = 6,

    // Not part of the file format, this will be set if all `no compression`
    // flags are set
    none = 257,

    _,

    // TODO: load this value
    pub const Options = union(Compression) {
        zlib: extern struct {
            compression_level: u4,
            _: u28,
            window_size: u4,
            _UNUSED: u12,
            strategies: Strategies,

            pub const Strategies = packed struct(u16) {
                default: bool,
                filtered: bool,
                huffman_only: bool,
                run_length_encoded: bool,
                fixed: bool,
                _: u11 = undefined,
            };
        },
        lzma: u0,
        lzo: extern struct {
            algorithm: Algorithm,
            compression_level: u4,
            _: u28,

            pub const Algorithm = enum(u32) {
                lzo1x_1 = 0,
                lzo1x_11 = 1,
                lzo1x_12 = 2,
                lzo1x_15 = 3,
                lzo1x_999 = 4,
            };
        },
        xz: extern struct {
            dictionary_size: u32,
            filters: Filters,

            pub const Filters = packed struct(u32) {
                x86: bool,
                powerpc: bool,
                ia64: bool,
                arm: bool,
                armthumb: bool,
                sparc: bool,
                _: u26 = undefined,
            };
        },
        lz4: extern struct {
            version: u32,
            flags: Flags,

            pub const Flags = packed struct(u32) {
                lz4_hc: bool,
                _: u31 = undefined,
            };
        },
        zstd: extern struct {
            compression_level: u32,
        },
    };
};

pub const Options = struct {
    offset: u64 = 0,

    cached_metadata_blocks: usize = 8,
    cached_data_blocks: usize = 8,
    cached_fragment_blocks: usize = 3,
};

pub const Decompressor = *const fn (
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize;

pub fn builtWithDecompression(comptime compression: Compression) bool {
    if (compression == .none) return true;
    return @field(build_options, "enable-" ++ @tagName(compression));
}

pub fn getDecompressor(kind: Compression) SquashFsError!Decompressor {
    switch (kind) {
        .zlib => {
            if (comptime builtWithDecompression(.zlib)) {
                if (build_options.@"use-zig-zlib") {
                    return @import("compression/zlib_zig.zig").decode;
                }

                return @import("compression/zlib_libdeflate.zig").decode;
            }
        },
        .lzma, .lzo => return error.InvalidCompression,
        .xz => {
            if (comptime builtWithDecompression(.xz)) {
                if (build_options.@"use-zig-xz") {
                    return @import("compression/xz_zig.zig").decode;
                }

                return @import("compression/xz_liblzma.zig").decode;
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
        .none => return noopDecode,
        else => return error.InvalidCompression,
    }

    return error.InvalidCompression;
}

pub fn noopDecode(
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize {
    _ = allocator;
    _ = out;

    return in.len;
}
