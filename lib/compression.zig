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

pub const Decompressor = struct {
    pub const VTable = struct {
        ptr: *anyopaque,

        decompressBlock: *const fn (
            *anyopaque,
            in: []const u8,
            out: []u8,
        ) DecompressError!usize,

        deinit: *const fn (*anyopaque) void,
    };

    vtable: VTable,

    pub fn init(T: type, allocator: std.mem.Allocator) Decompressor {
        return .{
            .vtable = .{
                .ptr = T.init(allocator),
                .decompressBlock = T.decompressBlock,
                .deinit = T.deinit,
            },
        };
    }

    pub fn decompressBlock(decompressor: Decompressor, in: []const u8, out: []u8) DecompressError!usize {
        return decompressor.vtable.decompressBlock(
            decompressor.vtable.ptr,
            in,
            out,
        );
    }

    pub fn deinit(decompressor: Decompressor) void {
        return decompressor.vtable.deinit(decompressor.vtable.ptr);
    }
};

pub const DecompressFn = *const fn (
    decompressor: *anyopaque,
    in: []const u8,
    out: []u8,
) DecompressError!usize;

pub fn getDecompressor(allocator: std.mem.Allocator, kind: Compression) SquashFsError!Decompressor {
    switch (kind) {
        .zlib => {
            const zlib_zig = @import("compression/zlib_zig.zig");
            const libdeflate = @import("compression/zlib_libdeflate.zig");
            const libz = @import("compression/zlib_libz.zig");

            switch (build_options.zlib_decompressor) {
                .zig_stdlib => return Decompressor.init(zlib_zig, allocator),
                .libdeflate_static, .libdeflate_dynamic => {
                    initDecompressionSymbolStatic(libdeflate) catch return error.Error;
                    return Decompressor.init(libdeflate, allocator);
                },
                .libdeflate_dynlib => {
                    initDecompressionSymbolDynlib(libdeflate, "libdeflate") catch return error.Error;
                    return Decompressor.init(libdeflate, allocator);
                },
                .libz_dynamic => {
                    initDecompressionSymbolStatic(libz) catch return error.Error;
                    return Decompressor.init(libz, allocator);
                },
                .libz_dynlib => {
                    initDecompressionSymbolDynlib(libz, "libz") catch return error.Error;
                    return Decompressor.init(libz, allocator);
                },
            }
        },
        .lzma, .lzo => return error.InvalidCompression,
        .xz => {
            const xz_zig = @import("compression/xz_zig.zig");
            const liblzma = @import("compression/xz_liblzma.zig");

            switch (build_options.xz_decompressor) {
                .zig_stdlib => return Decompressor.init(xz_zig, allocator),
                .liblzma_static, .liblzma_dynamic => {
                    initDecompressionSymbolStatic(liblzma) catch return error.Error;
                    return Decompressor.init(liblzma, allocator);
                },
                .liblzma_dynlib => {
                    initDecompressionSymbolDynlib(liblzma, "liblzma") catch return error.Error;
                    return Decompressor.init(liblzma, allocator);
                },
            }
        },
        .lz4 => {
            const lz4_zig = @import("compression/lz4_zig.zig");
            const liblz4 = @import("compression/lz4_liblz4.zig");

            switch (build_options.lz4_decompressor) {
                .lzig4 => return Decompressor.init(lz4_zig, allocator),
                .liblz4_static, .liblz4_dynamic => {
                    initDecompressionSymbolStatic(liblz4) catch return error.Error;
                },
                .liblz4_dynlib => {
                    initDecompressionSymbolDynlib(liblz4, "liblz4") catch return error.Error;
                },
            }

            return Decompressor.init(liblz4, allocator);
        },
        .zstd => {
            const zstd_zig = @import("compression/zstd_zig.zig");
            const libzstd = @import("compression/zstd_libzstd.zig");

            switch (build_options.zstd_decompressor) {
                .zig_stdlib => return Decompressor.init(zstd_zig, allocator),
                .libzstd_static, .libzstd_dynamic => {
                    initDecompressionSymbolStatic(libzstd) catch return error.Error;
                    return Decompressor.init(libzstd, allocator);
                },
                .libzstd_dynlib => {
                    initDecompressionSymbolDynlib(libzstd, "libzstd") catch return error.Error;
                    return Decompressor.init(libzstd, allocator);
                },
            }
        },
        .none => return Decompressor.init(FakeDecoder, allocator),
        else => return error.InvalidCompression,
    }

    return error.InvalidCompression;
}

pub fn builtWithDecompression(comptime compression: Compression) bool {
    if (compression == .none) return true;

    const decl_name = "static_" ++ @tagName(compression);

    return @hasDecl(build_options, decl_name) and @field(build_options, decl_name);
}

fn initDecompressionSymbolStatic(
    comptime T: type,
) !void {
    inline for (@typeInfo(T.required_symbols).Struct.decls) |decl| {
        @field(T.required_symbols, decl.name) = @extern(
            @TypeOf(@field(T.required_symbols, decl.name)),
            .{ .name = decl.name },
        );
    }

    return;
}

// Initializes decompression function pointers for C-ABI compression libs
// If `static_[DECOMPRESSOR]` is not given, an attempt will be made to
// dlload the library from the system
fn initDecompressionSymbolDynlib(
    comptime T: type,
    comptime library_name: []const u8,
) !void {
    const path = std.fmt.comptimePrint(
        "{s}.so",
        .{library_name},
    );

    // TODO: close libs
    var lib = try DynLib.open(path);

    inline for (@typeInfo(T.required_symbols).Struct.decls) |decl| {
        @field(T.required_symbols, decl.name) = lib.lookup(
            @TypeOf(@field(T.required_symbols, decl.name)),
            decl.name,
        ) orelse return error.SymbolNotFound;
    }
}

pub const FakeDecoder = struct {
    pub fn init(allocator: std.mem.Allocator) *anyopaque {
        _ = allocator;

        return undefined;
    }

    pub fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    // The decompressor should never be called on uncompressed blocks so just
    // crash here
    pub fn decompressBlock(
        _: *anyopaque,
        _: []const u8,
        _: []u8,
    ) DecompressError!usize {
        unreachable;
    }
};
