const std = @import("std");
const io = std.io;
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;
const xz = std.compress.xz;
const zstd = std.compress.zstd;
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stat.h"); // squashfuse (not system) stat header
    @cInclude("squashfuse.h");
    @cInclude("common.h");
});

pub const SquashFsError = error{
    Error, // Generic error
    InvalidFormat, // Unknown file format
    InvalidVersion, // Unsupported version
    InvalidCompression, // Unsupported compression algorithm
    UnsupportedFeature, // Unsupported feature
    NotRegularFile,
};

// Converts a C error code to a Zig error enum
fn SquashFsErrorFromInt(err: c_uint) SquashFsError!void {
    return switch (err) {
        0 => {},
        2 => SquashFsError.InvalidFormat,
        3 => SquashFsError.InvalidVersion,
        4 => SquashFsError.InvalidCompression,
        5 => SquashFsError.UnsupportedFeature,

        else => SquashFsError.Error,
    };
}

pub const InodeId = c.sqfs_inode_id;

pub const SquashFs = struct {
    internal: c.sqfs,
    version: std.SemanticVersion,
    file: fs.File,

    pub const Compression = enum(c_int) {
        zlib = 1,
        lzma = 2,
        lzo = 3,
        xz = 4,
        lz4 = 5,
        zstd = 6,
    };

    pub const Options = struct {
        offset: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, opts: Options) !SquashFs {
        // Once more C code is ported over, initializing the SquashFS will
        // require an allocator, so add it to the API now even though it isn't
        // yet used
        _ = allocator;

        var sqfs = SquashFs{
            .internal = undefined,
            .version = .{
                .major = undefined,
                .minor = undefined,
                .patch = 0,
            },
            .file = try std.fs.cwd().openFile(path, .{}),
        };

        // Populate internal squashfuse struct
        try SquashFsErrorFromInt(c.sqfs_init(
            &sqfs.internal,
            sqfs.file.handle,
            opts.offset,
        ));

        // Set version
        c.sqfs_version(
            &sqfs.internal,
            @ptrCast(&sqfs.version.major),
            @ptrCast(&sqfs.version.minor),
        );

        return sqfs;
    }

    pub inline fn deinit(sqfs: *SquashFs) void {
        c.sqfs_destroy(&sqfs.internal);
        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: InodeId) !Inode {
        var sqfs_inode: c.sqfs_inode = undefined;

        try SquashFsErrorFromInt(c.sqfs_inode_get(&sqfs.internal, &sqfs_inode, id));

        return Inode{ .internal = sqfs_inode, .parent = sqfs, .kind = @enumFromInt(sqfs_inode.base.inode_type) };
    }

    pub inline fn getRootInode(sqfs: *SquashFs) Inode {
        return sqfs.getInode(
            sqfs.internal.sb.root_inode,
        ) catch unreachable;
    }

    pub const Inode = struct {
        internal: c.sqfs_inode,
        parent: *SquashFs,
        kind: File.Kind,
        pos: u64 = 0,

        /// Reads the link target into `buf`
        pub fn readLink(self: *Inode, buf: []u8) ![]const u8 {
            var size = buf.len;

            const err = c.sqfs_readlink(
                &self.parent.internal,
                &self.internal,
                buf.ptr,
                &size,
            );
            try SquashFsErrorFromInt(err);

            return std.mem.sliceTo(
                @as([*:0]const u8, @ptrCast(buf.ptr)),
                0,
            );
        }

        pub fn readLinkZ(self: *Inode, buf: []u8) ![:0]const u8 {
            try std.fmt.bufPrintZ(buf, "{s}", .{
                try self.readLink,
            });
        }

        /// Wrapper of `sqfs_read_range`
        /// Use for reading one byte buffer at a time
        /// Retruns the amount of bytes read
        pub fn read(self: *Inode, buf: []u8) !usize {
            if (self.kind != .file) {
                return SquashFsError.NotRegularFile;
            }

            // squashfuse writes the amount of bytes read back into the `buffer
            // length` variable, so we create that here
            var buf_len: c.sqfs_off_t = @intCast(buf.len);

            const err = c.sqfs_read_range(
                &self.parent.internal,
                &self.internal,
                @intCast(self.pos),
                &buf_len,
                @ptrCast(buf),
            );

            try SquashFsErrorFromInt(err);

            self.pos += @intCast(buf_len);

            return @intCast(buf_len);
        }

        pub const SeekableStream = io.SeekableStream(
            Inode,
            SeekError,
            GetSeekPosError,
            seekTo,
            seekBy,
            getPos,
            getEndPos,
        );

        pub const setEndPos = @compileError("setEndPos not possible for SquashFS (read-only filesystem)");

        pub const GetSeekPosError = os.SeekError || os.FStatError;
        pub const SeekError = os.SeekError || error{InvalidSeek};

        // TODO: handle invalid seeks
        pub fn seekTo(self: *Inode, pos: u64) SeekError!void {
            const end = self.getEndPos() catch return SeekError.Unseekable;

            if (pos > end) {
                return SeekError.InvalidSeek;
            }

            self.pos = pos;
        }

        pub fn seekBy(self: *Inode, pos: i64) SeekError!void {
            self.pos += pos;
        }

        pub fn seekFromEnd(self: *Inode, pos: i64) SeekError!void {
            const end = self.getEndPos() catch return SeekError.Unseekable;
            self.pos = end + pos;
        }

        pub fn getPos(self: *const Inode) GetSeekPosError!u64 {
            return self.pos;
        }

        pub fn getEndPos(self: *const Inode) GetSeekPosError!u64 {
            return @intCast(self.internal.xtra.reg.file_size);
        }

        pub const Reader = std.io.Reader(Inode, std.os.ReadError, read);

        pub fn reader(self: *Inode) Reader {
            return .{ .context = self };
        }

        pub inline fn stat(self: *Inode) !fs.File.Stat {
            const st = try self.statC();

            return fs.File.Stat.fromSystem(st);
        }

        // Like `Inode.stat` but returns the OS native stat format
        pub fn statC(self: *Inode) !os.Stat {
            var st = std.mem.zeroes(os.Stat);

            const err = c.sqfs_stat(&self.parent.internal, &self.internal, @ptrCast(&st));
            try SquashFsErrorFromInt(err);

            return st;
        }

        pub fn iterate(self: *Inode) !Iterator {
            // TODO: error handling
            // squashfuse already does errors, which get caught by
            // `SquashFsErrorFromInt` but it's probably better to handle them
            // in Zig as I plan on slowly reimplementing a lot of functions
            //if (self.kind != .Directory)

            // Open dir
            // TODO: add offset
            var dir: c.sqfs_dir = undefined;
            try SquashFsErrorFromInt(c.sqfs_dir_open(&self.parent.internal, &self.internal, &dir, 0));

            return .{ .dir = self.*, .internal = dir, .parent = self.parent };
        }

        pub const Iterator = struct {
            dir: Inode,
            internal: c.sqfs_dir,
            parent: *SquashFs,
            // SquashFS has max name length of 256. Add another byte for null
            name_buf: [257]u8 = undefined,

            pub const Entry = struct {
                id: InodeId,
                parent: *SquashFs,

                name: [:0]const u8,
                kind: File.Kind,

                pub inline fn inode(self: *const Entry) Inode {
                    var sqfs_inode: c.sqfs_inode = undefined;

                    // This should never fail
                    // if it does, something went very wrong (like messing with
                    // the inode ID)
                    const err = c.sqfs_inode_get(
                        &self.parent.internal,
                        &sqfs_inode,
                        self.id,
                    );
                    if (err != 0) unreachable;

                    return Inode{
                        .internal = sqfs_inode,
                        .parent = self.parent,
                        .kind = self.kind,
                    };
                }
            };

            /// Wraps `sqfs_dir_next`
            /// Returns an entry for the next inode in the directory
            pub fn next(self: *Iterator) !?Entry {
                var sqfs_dir_entry: c.sqfs_dir_entry = undefined;

                sqfs_dir_entry.name = &self.name_buf;

                var err: c.sqfs_err = undefined;

                const found = c.sqfs_dir_next(
                    &self.parent.internal,
                    &self.internal,
                    &sqfs_dir_entry,
                    &err,
                );

                try SquashFsErrorFromInt(err);
                if (!found) return null;

                // Append null byte
                self.name_buf[sqfs_dir_entry.name_size] = '\x00';

                return .{
                    .id = sqfs_dir_entry.inode,
                    .name = self.name_buf[0..sqfs_dir_entry.name_size :0],
                    .kind = @enumFromInt(sqfs_dir_entry.type),
                    .parent = self.parent,
                };
            }
        };

        pub fn walk(self: *Inode, allocator: std.mem.Allocator) !Walker {
            var name_buffer = std.ArrayList(u8).init(allocator);
            errdefer name_buffer.deinit();

            var stack = std.ArrayList(Walker.StackItem).init(allocator);
            errdefer stack.deinit();

            try stack.append(Walker.StackItem{
                .iter = try self.iterate(),
                .dirname_len = 0,
            });

            return Walker{
                .stack = stack,
                .name_buffer = name_buffer,
            };
        }

        pub const Walker = struct {
            stack: std.ArrayList(StackItem),
            name_buffer: std.ArrayList(u8),

            const StackItem = struct {
                iter: Inode.Iterator,
                dirname_len: usize,
            };

            pub const Entry = struct {
                id: InodeId,
                parent: *SquashFs,

                dir: Inode,
                kind: File.Kind,
                path: [:0]const u8,
                basename: []const u8,

                pub inline fn inode(self: *const Entry) Inode {
                    var sqfs_inode: c.sqfs_inode = undefined;

                    // This should never fail
                    // if it does, something went very wrong
                    const err = c.sqfs_inode_get(
                        &self.parent.internal,
                        &sqfs_inode,
                        self.id,
                    );
                    if (err != 0) unreachable;

                    return Inode{
                        .internal = sqfs_inode,
                        .parent = self.parent,
                        .kind = self.kind,
                    };
                }
            };

            // Copied and slightly modified from Zig stdlib
            // <https://github.com/ziglang/zig/blob/master/lib/std/fs.zig>
            pub fn next(self: *Walker) !?Entry {
                while (self.stack.items.len != 0) {
                    // `top` and `containing` become invalid after appending to `self.stack`
                    var top = &self.stack.items[self.stack.items.len - 1];
                    var containing = top;
                    var dirname_len = top.dirname_len;

                    if (try top.iter.next()) |entry| {
                        self.name_buffer.shrinkRetainingCapacity(dirname_len);

                        if (self.name_buffer.items.len != 0) {
                            try self.name_buffer.append(std.fs.path.sep);
                            dirname_len += 1;
                        }

                        try self.name_buffer.appendSlice(entry.name);

                        if (entry.kind == .directory) {
                            var new_dir = entry.inode();

                            {
                                try self.stack.append(StackItem{
                                    .iter = try new_dir.iterate(),
                                    .dirname_len = self.name_buffer.items.len,
                                });
                                top = &self.stack.items[self.stack.items.len - 1];
                                containing = &self.stack.items[self.stack.items.len - 2];
                            }
                        }

                        // Append null byte
                        try self.name_buffer.append('\x00');

                        const path = self.name_buffer.items[0 .. self.name_buffer.items.len - 1 :0];
                        const basename = self.name_buffer.items[dirname_len .. self.name_buffer.items.len - 1 :0];

                        return .{
                            .dir = containing.iter.dir,
                            .basename = basename,
                            .id = entry.id,
                            .parent = entry.parent,
                            .path = path,
                            .kind = entry.kind,
                        };
                    }

                    _ = self.stack.pop();
                }

                return null;
            }

            pub fn deinit(self: *Walker) void {
                self.stack.deinit();
                self.name_buffer.deinit();
            }
        };

        /// Extracts an inode from the SquashFS image to `dest` using the buffer
        pub fn extract(self: *Inode, buf: []u8, dest: []const u8) !void {
            const cwd = fs.cwd();

            switch (self.kind) {
                .file => {
                    var f = try cwd.createFile(dest, .{});
                    defer f.close();

                    var off: usize = 0;
                    const fsize: usize = self.internal.xtra.reg.file_size;

                    while (off < fsize) {
                        //                        const read_bytes = try self.read(buf, off);
                        const read_bytes = try self.read(buf);
                        off += read_bytes;

                        _ = try f.write(buf[0..read_bytes]);
                    }

                    // Change the mode of the file to match the inode contained in the
                    // SquashFS image
                    const st = try self.stat();
                    try f.chmod(st.mode);
                },

                .directory => {
                    try cwd.makeDir(dest);
                },

                // TODO: implement for other types
                else => @panic("NEI for file type"),
            }
        }
    };

    pub const File = struct {
        pub const Kind = enum(u8) {
            directory = 1,
            file,
            sym_link,
            block_device,
            character_device,
            named_pipe,
            unix_domain_socket,

            // Not really sure what these are tbh, but squashfuse has entries for
            // them
            l_directory,
            l_file,
            l_sym_link,
            l_block_device,
            l_character_device,
            l_named_pipe,
            l_unix_domain_socket,
        };
    };
};

// I'm sure there's a better way to do this...
// Zig won't compile them in if they aren't used, but this still feels like acrime
// crime.
extern fn zig_zlib_decode([*]u8, usize, [*]u8, *usize) c.sqfs_err;
extern fn zig_xz_decode([*]u8, usize, [*]u8, *usize) c.sqfs_err;
extern fn zig_zstd_decode([*]u8, usize, [*]u8, *usize) c.sqfs_err;
extern fn zig_lz4_decode([*]u8, usize, [*]u8, *usize) c.sqfs_err;
extern fn zig_lzo_decode([*]u8, usize, [*]u8, *usize) c.sqfs_err;

export fn sqfs_decompressor_get(kind: SquashFs.Compression) ?*const fn ([*]u8, usize, [*]u8, *usize) callconv(.C) c.sqfs_err {
    switch (kind) {
        .zlib => {
            if (comptime build_options.enable_zlib) return zig_zlib_decode;
        },
        .lzma => return null,
        .xz => {
            if (comptime build_options.enable_xz) return zig_xz_decode;
        },
        .lzo => {
            if (comptime build_options.enable_lzo) return zig_lzo_decode;
        },
        .lz4 => {
            if (comptime build_options.enable_lz4) return zig_lz4_decode;
        },
        .zstd => {
            if (comptime build_options.enable_zstd) return zig_zstd_decode;
        },
    }

    return null;
}

// Define C symbols for compression algos
// TODO: add more Zig-implemented algos if they're performant
usingnamespace if (build_options.enable_xz)
    struct {
        export fn zig_xz_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
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
    }
else
    struct {};

usingnamespace if (build_options.enable_zlib)
    struct {
        const ldef = @cImport({
            @cInclude("libdeflate.h");
        });

        var ldef_decompressor: ?*ldef.libdeflate_decompressor = null;

        export fn zig_zlib_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
            if (ldef_decompressor == null) {
                ldef_decompressor = ldef.libdeflate_alloc_decompressor();
            }

            const err = ldef.libdeflate_zlib_decompress(
                ldef_decompressor,
                in,
                in_size,
                out,
                out_size.*,
                out_size,
            );

            if (err != ldef.LIBDEFLATE_SUCCESS) {
                return c.SQFS_ERR;
            }

            return c.SQFS_OK;
        }
    }
else
    struct {};

usingnamespace if (build_options.enable_lz4)
    struct {
        const lz = @cImport({
            @cInclude("lz4.h");
        });
        export fn zig_lz4_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
            const err = lz.LZ4_decompress_safe(
                in,
                out,
                @intCast(in_size),
                @intCast(out_size.*),
            );

            if (err < 0) {
                return c.SQFS_ERR;
            }

            out_size.* = @intCast(err);

            return c.SQFS_OK;
        }
    }
else
    struct {};

usingnamespace if (build_options.enable_zstd)
    if (build_options.use_zig_zstd)
        struct {
            export fn zig_zstd_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                var stream = std.io.fixedBufferStream(in[0..in_size]);

                var allocator = std.heap.c_allocator;

                var decompressor = zstd.decompressStream(
                    allocator,
                    stream.reader(),
                );

                defer decompressor.deinit();

                var buf = out[0..out_size.*];

                out_size.* = decompressor.read(buf) catch return c.SQFS_ERR;

                return c.SQFS_OK;
            }
        }
    else
        struct {
            const czstd = @cImport({
                @cInclude("zstd.h");
            });
            export fn zig_zstd_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                const err = czstd.ZSTD_decompress(
                    out,
                    out_size.*,
                    in,
                    in_size,
                );

                if (czstd.ZSTD_isError(err) != 0) {
                    return c.SQFS_ERR;
                }

                out_size.* = err;

                return c.SQFS_OK;
            }
        }
else
    struct {};
