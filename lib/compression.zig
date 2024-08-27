const std = @import("std");
const DynLib = std.DynLib;
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
            _36: u12,
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
                _,
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
                _6: u26 = undefined,
            };
        },
        lz4: extern struct {
            version: u32,
            flags: Flags,

            pub const Flags = packed struct(u32) {
                lz4_hc: bool,
                _1: u31 = undefined,
            };
        },
        zstd: extern struct {
            compression_level: u32,
        },
    };
};

pub const Decompressor = *const fn (
    allocator: std.mem.Allocator,
    in: []const u8,
    out: []u8,
) DecompressError!usize;

pub fn getDecompressor(kind: Compression) SquashFsError!Decompressor {
    switch (kind) {
        .zlib => {
            const libdeflate = @import("compression/zlib_libdeflate.zig");
            const libz = @import("compression/zlib_libz.zig");

            return switch (build_options.zlib_decompressor) {
                .zig_stdlib => @import("compression/zlib_zig.zig").decode,
                .libdeflate => blk: {
                    initDecompressionSymbol(libdeflate, .zlib, "libdeflate") catch return error.Error;

                    break :blk libdeflate.decode;
                },
                .libz => blk: {
                    initDecompressionSymbol(libz, .zlib, "libz") catch return error.Error;

                    break :blk libz.decode;
                },
            };
        },
        .lzma, .lzo => return error.InvalidCompression,
        .xz => {
            if (build_options.xz_decompressor == .zig_stdlib) {
                return @import("compression/xz_zig.zig").decode;
            }

            const libxz = @import("compression/xz_liblzma.zig");
            initDecompressionSymbol(libxz, .xz, "liblzma") catch return error.Error;

            return libxz.decode;
        },
        .lz4 => {
            const liblz4 = @import("compression/lz4_liblz4.zig");
            initDecompressionSymbol(liblz4, .lz4, "liblz4") catch return error.Error;

            return liblz4.decode;
        },
        .zstd => {
            if (build_options.zstd_decompressor == .zig_stdlib) {
                return @import("compression/zstd_zig.zig").decode;
            }

            const libzstd = @import("compression/zstd_libzstd.zig");
            initDecompressionSymbol(libzstd, .zstd, "libzstd") catch return error.Error;

            return libzstd.decode;
        },
        .none => return fakeDecode,
        else => return error.InvalidCompression,
    }

    return error.InvalidCompression;
}

pub fn builtWithDecompression(comptime compression: Compression) bool {
    if (compression == .none) return true;

    const decl_name = "static_" ++ @tagName(compression);

    return @hasDecl(build_options, decl_name) and @field(build_options, decl_name);
}

// Initializes decompression function pointers for C-ABI compression libs
// If `static_[DECOMPRESSOR]` is not given, an attempt will be made to
// dlload the library from the system
fn initDecompressionSymbol(
    comptime T: type,
    comptime compression: Compression,
    comptime library_name: []const u8,
) !void {
    if (comptime builtWithDecompression(compression)) {
        inline for (@typeInfo(T.required_symbols).Struct.decls) |decl| {
            @field(T.required_symbols, decl.name) = @extern(
                @TypeOf(@field(T.required_symbols, decl.name)),
                .{ .name = decl.name },
            );
        }

        return;
    }

    var found = false;

    // Looks like it wasn't statically linked, attempt to find the library on
    // the system
    inline for (.{
        "/lib/{s}.so.1",
        "/lib64/{s}.so.1",
        "/usr/lib/{s}.so.1",
        "/usr/lib64/{s}.so.1",
    }) |fmt| {
        const path = std.fmt.comptimePrint(
            fmt,
            .{library_name},
        );

        // TODO: close libs
        var lib = DynLib.open(path) catch |err| {
            switch (err) {
                error.FileNotFound => comptime continue,
                else => return err,
            }
        };

        inline for (@typeInfo(T.required_symbols).Struct.decls) |decl| {
            @field(T.required_symbols, decl.name) = lib.lookup(
                @TypeOf(@field(T.required_symbols, decl.name)),
                decl.name,
            ) orelse return error.SymbolNotFound;
        }

        found = true;
        break;
    }

    if (!found) return error.DynLibNotFound;
}

// Since the decompressor will never be called on uncompressed blocks,
// just give a function that doesn't do anything
pub fn fakeDecode(
    _: std.mem.Allocator,
    _: []const u8,
    _: []u8,
) DecompressError!usize {
    unreachable;
}
