const std = @import("std");
const io = std.io;
const os = std.os;
const fs = std.fs;
const xz = std.compress.xz;
const zstd = std.compress.zstd;
const build_options = @import("build_options");

const table = @import("table.zig");

const c = @cImport({
    @cInclude("squashfuse.h");
    @cInclude("common.h");

    @cInclude("swap.h");
});

pub const SquashFsError = error{
    Error,
    InvalidFormat,
    InvalidVersion,
    InvalidCompression,
    UnsupportedFeature,
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
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
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
        var sqfs = SquashFs{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .internal = undefined,
            .version = undefined,
            .file = try fs.cwd().openFile(path, .{}),
        };

        // Populate internal squashfuse struct
        try initInternal(
            allocator,
            sqfs.arena.allocator(),
            &sqfs.internal,
            sqfs.file.handle,
            opts.offset,
        );

        // Set version
        sqfs.version = .{
            .major = @intCast(sqfs.internal.sb.s_major),
            .minor = @intCast(sqfs.internal.sb.s_minor),
            .patch = 0,
        };

        return sqfs;
    }

    pub fn deinit(sqfs: *SquashFs) void {
        table.deinitTable(
            sqfs.allocator,
            @ptrCast(&sqfs.internal.id_table),
            sqfs.internal.sb.no_ids,
        );

        table.deinitTable(
            sqfs.allocator,
            @ptrCast(&sqfs.internal.frag_table),
            sqfs.internal.sb.fragments,
        );

        if (sqfs.internal.sb.lookup_table_start != c.SQUASHFS_INVALID_BLK) {
            table.deinitTable(
                sqfs.allocator,
                @ptrCast(&sqfs.internal.export_table),
                sqfs.internal.sb.inodes,
            );
        }

        // Deinit caches
        sqfs.arena.deinit();

        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: InodeId) !Inode {
        var sqfs_inode: c.sqfs_inode = undefined;

        try SquashFsErrorFromInt(c.sqfs_inode_get(
            &sqfs.internal,
            &sqfs_inode,
            id,
        ));

        return Inode{
            .internal = sqfs_inode,
            .parent = sqfs,
            .kind = @enumFromInt(sqfs_inode.base.inode_type),
        };
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
        pub fn readLink(inode: *Inode, buf: []u8) ![]const u8 {
            if (inode.kind != .sym_link) {
                // TODO: rename
                return error.NotLink;
            }

            const len = inode.internal.xtra.symlink_size;

            if (len >= buf.len) {
                return error.NoSpaceLeft;
            }

            var cur = inode.internal.next;
            try SquashFsErrorFromInt(c.sqfs_md_read(
                &inode.parent.internal,
                &cur,
                buf.ptr,
                len,
            ));

            return buf[0..len];
        }

        // TODO: handle buffer when too small
        pub fn readLinkZ(self: *Inode, buf: []u8) ![:0]const u8 {
            const link_target = try self.readLink(buf[0 .. buf.len - 1]);
            buf[link_target.len] = '\x00';

            return buf[0..link_target.len :0];
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

            try SquashFsErrorFromInt(c.sqfs_read_range(
                &self.parent.internal,
                &self.internal,
                @intCast(self.pos),
                &buf_len,
                @ptrCast(buf),
            ));

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

        pub const Reader = io.Reader(Inode, os.ReadError, read);

        pub fn reader(self: *Inode) Reader {
            return .{ .context = self };
        }

        pub inline fn stat(self: *Inode) !fs.File.Stat {
            const st = try self.statC();

            return fs.File.Stat.fromSystem(st);
        }

        extern fn sqfs_stat(*c.sqfs, *c.sqfs_inode, *os.Stat) c.sqfs_err;

        // Like `Inode.stat` but returns the OS native stat format
        pub fn statC(self: *Inode) !os.Stat {
            var st = std.mem.zeroes(os.Stat);

            try SquashFsErrorFromInt(sqfs_stat(
                &self.parent.internal,
                &self.internal,
                @ptrCast(&st),
            ));

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
            try SquashFsErrorFromInt(c.sqfs_dir_open(
                &self.parent.internal,
                &self.internal,
                &dir,
                0,
            ));

            return .{
                .dir = self.*,
                .internal = dir,
                .parent = self.parent,
            };
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

                const found = try dirNext(
                    &self.parent.internal,
                    &self.internal,
                    &sqfs_dir_entry,
                );

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
                            try self.name_buffer.append(fs.path.sep);
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
                    const fsize: u64 = self.internal.xtra.reg.file_size;

                    while (off < fsize) {
                        const read_bytes = try self.read(buf);
                        off += read_bytes;

                        _ = try f.write(buf[0..read_bytes]);
                    }

                    // Change the mode of the file to match the inode contained
                    // in the SquashFS image
                    const st = try self.stat();
                    try f.chmod(st.mode);
                },

                .directory => {
                    try cwd.makeDir(dest);
                },

                .sym_link => {
                    var link_target_buf: [os.PATH_MAX]u8 = undefined;

                    const link_target = try self.readLink(&link_target_buf);

                    // TODO: check if dir
                    // TODO: why does it make a difference? squashfuse appears
                    // to just call `symlink` on the target
                    try cwd.symLink(
                        link_target,
                        dest,
                        .{ .is_directory = false },
                    );
                },

                // TODO: implement for other types
                else => {
                    var panic_buf: [64]u8 = undefined;

                    const panic_str = try std.fmt.bufPrint(
                        &panic_buf,
                        "Inode.extract not yet implemented for file type `{s}`",
                        .{@tagName(self.kind)},
                    );

                    @panic(panic_str);
                },
            }
        }
    };

    pub const File = struct {
        pub const Kind = enum(u8) {
            directory = 1,
            file = 2,
            sym_link = 3,
            block_device = 4,
            character_device = 5,
            named_pipe = 6,
            unix_domain_socket = 7,

            // Not really sure what these are tbh, but squashfuse has entries
            // for them
            l_directory = 8,
            l_file = 9,
            l_sym_link = 10,
            l_block_device = 11,
            l_character_device = 12,
            l_named_pipe = 13,
            l_unix_domain_socket = 14,
        };
    };
};

// I'm sure there's a better way to do this...
// Zig won't compile them in if they aren't used, but this still feels like a
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

fn dirMdRead(
    sqfs: *c.sqfs,
    dir: *c.sqfs_dir,
    buf: ?*anyopaque,
    size: usize,
) !void {
    dir.offset += @intCast(size);

    const err = c.sqfs_md_read(sqfs, &dir.cur, buf, size);
    if (err != 0) {
        return error.Error;
    }
}

fn dirNext(
    sqfs: *c.sqfs,
    dir: *c.sqfs_dir,
    entry: *c.sqfs_dir_entry,
) !bool {
    var e: c.squashfs_dir_entry = undefined;

    entry.offset = dir.offset;

    while (dir.header.count == 0) {
        if (dir.offset >= dir.total) {
            return false;
        }

        try dirMdRead(sqfs, dir, &dir.header, @sizeOf(@TypeOf(dir.header)));

        dir.header = @bitCast(
            std.mem.littleToNative(
                u96,
                @bitCast(dir.header),
            ),
        );

        //        c.sqfs_swapin_dir_header(&dir.header);
        dir.header.count += 1;
    }

    try dirMdRead(sqfs, dir, &e, @sizeOf(@TypeOf(e)));

    e = @bitCast(
        std.mem.littleToNative(
            u64,
            @bitCast(e),
        ),
    );

    //c.sqfs_swapin_dir_entry(&e);

    dir.header.count -= 1;

    entry.type = e.type;
    entry.name_size = e.size + 1;
    entry.inode = (@as(u64, @intCast(dir.header.start_block)) << 16) + e.offset;
    entry.inode_number = dir.header.inode_number + e.inode_number;

    try dirMdRead(sqfs, dir, entry.name, entry.name_size);

    return true;
}

// TODO: refactor, move into the main init method
fn initInternal(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    sqfs: *c.sqfs,
    fd: c.sqfs_fd_t,
    offset: usize,
) !void {
    var err: c.sqfs_err = c.SQFS_OK;
    sqfs.* = std.mem.zeroes(c.sqfs);

    sqfs.fd = fd;
    sqfs.offset = offset;

    const SqfsSb = @TypeOf(sqfs.sb);

    //if (c.sqfs_pread(fd, &sqfs.sb, @sizeOf(SqfsSb), @intCast(sqfs.offset)) != @sizeOf(SqfsSb)) {
    const sb_buf: [*]u8 = @ptrCast(&sqfs.sb);
    if (try std.os.pread(fd, sb_buf[0..@sizeOf(SqfsSb)], @intCast(sqfs.offset)) != @sizeOf(SqfsSb)) {
        return SquashFsError.InvalidFormat;
    }

    // Swap endianness if necessary
    sqfs.sb = @bitCast(
        std.mem.littleToNative(
            u768,
            @bitCast(sqfs.sb),
        ),
    );

    //c.sqfs_swapin_super_block(&sqfs.sb);

    if (sqfs.sb.s_magic != c.SQUASHFS_MAGIC) {
        if (sqfs.sb.s_magic != c.SQFS_MAGIC_SWAP) {
            return SquashFsError.InvalidFormat;
        }

        sqfs.sb.s_major = @byteSwap(sqfs.sb.s_major);
        sqfs.sb.s_minor = @byteSwap(sqfs.sb.s_minor);
    }

    if (sqfs.sb.s_major != c.SQUASHFS_MAJOR or sqfs.sb.s_minor > c.SQUASHFS_MINOR) {
        return SquashFsError.InvalidVersion;
    }

    sqfs.decompressor = @ptrCast(
        sqfs_decompressor_get(@enumFromInt(sqfs.sb.compression)),
    );
    if (sqfs.decompressor == null) {
        return SquashFsError.InvalidCompression;
    }

    try table.initTable(
        allocator,
        @ptrCast(&sqfs.id_table),
        fd,
        @intCast(sqfs.sb.id_table_start + sqfs.offset),
        4,
        sqfs.sb.no_ids,
    );

    try table.initTable(
        allocator,
        @ptrCast(&sqfs.frag_table),
        fd,
        @intCast(sqfs.sb.fragment_table_start + sqfs.offset),
        @sizeOf(c.squashfs_fragment_entry),
        sqfs.sb.fragments,
    );

    if (sqfs.sb.lookup_table_start != c.SQUASHFS_INVALID_BLK) {
        try table.initTable(
            allocator,
            @ptrCast(&sqfs.export_table),
            fd,
            @intCast(sqfs.sb.lookup_table_start + sqfs.offset),
            8,
            sqfs.sb.inodes,
        );
    }

    const DATA_CACHED_BLKS = 1;
    const FRAG_CACHED_BLKS = 3;

    err |= c.sqfs_xattr_init(sqfs);

    // TODO: clean up memory if fail
    try initBlockCache(arena, &sqfs.md_cache, c.SQUASHFS_CACHED_BLKS);
    try initBlockCache(arena, &sqfs.data_cache, DATA_CACHED_BLKS);
    try initBlockCache(arena, &sqfs.frag_cache, FRAG_CACHED_BLKS);
    try initBlockIdx(arena, &sqfs.blockidx);

    if (err != 0) {
        //c.sqfs_destroy(sqfs);
        return SquashFsError.Error;
    }
    // TODO SUBDIR
}

fn initBlockCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    count: usize,
) !void {
    try initCache(
        allocator,
        cache,
        @sizeOf(c.sqfs_block_cache_entry),
        count,
        //@ptrFromInt(0x69),
        @ptrCast(&noop),
    );
}

fn initBlockIdx(allocator: std.mem.Allocator, cache: *c.sqfs_cache) !void {
    try initCache(
        allocator,
        cache,
        @sizeOf(**c.sqfs_blockidx_entry),
        c.SQUASHFS_META_SLOTS,
        @ptrCast(&noop),
    );
}

fn deinitBlockCache(
    allocator: std.mem.Allocator,
    data: ?*anyopaque,
) !void {
    const entry: *c.sqfs_block_cache_entry = @ptrCast(data.?);

    if (c.sqfs_block_deref(entry.block) != 0) {
        allocator.free(entry.block.data);
        allocator.free(entry.block);
    }
}

const sqfs_cache_internal = extern struct {
    buf: [*]u8,

    dispose: c.sqfs_cache_dispose,

    size: usize,
    count: usize,
    next: usize,
};

const sqfs_cache_entry_hdr = extern struct {
    valid: c_int,
    idx: c.sqfs_cache_idx,
};

fn initCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    size: usize,
    count: usize,
    dispose: c.sqfs_cache_dispose,
) !void {
    var temp = try allocator.create(sqfs_cache_internal);

    temp.size = size + @sizeOf(sqfs_cache_entry_hdr);
    temp.count = count;
    temp.dispose = dispose;
    temp.next = 0;

    temp.buf = (try allocator.alloc(u8, count * temp.size)).ptr;

    cache.* = @ptrCast(temp);
}

// Define C symbols for compression algos
// Note: All symbol definitions (eg: LZ4_decompress_safe) MUST be kept
// perfectly in sync with the headers. The only reason I'm not using the
// headers anymore is because it's easier to integrate into the Zig package
// manager (at least according to what I know) without them. The likely hood
// that the ABI in any of these compression libraries will change is
// essentially zero, but it should be noted anyway.
//
// TODO: add more Zig-implemented algos if they're performant
usingnamespace if (build_options.enable_xz)
    if (build_options.use_zig_xz)
        struct {
            export fn zig_xz_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                var stream = io.fixedBufferStream(in[0..in_size]);

                const allocator = std.heap.c_allocator;

                var decompressor = xz.decompress(
                    allocator,
                    stream.reader(),
                ) catch return c.SQFS_ERR;

                defer decompressor.deinit();

                const buf = out[0..out_size.*];

                out_size.* = decompressor.read(buf) catch return c.SQFS_ERR;

                return c.SQFS_OK;
            }
        }
    else
        struct {
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

            export fn zig_xz_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                var memlimit: u64 = 0xffff_ffff_ffff_ffff;

                var inpos: usize = 0;
                var outpos: usize = 0;

                const err = lzma_stream_buffer_decode(
                    &memlimit,
                    0,
                    null,
                    in,
                    &inpos,
                    in_size,
                    out,
                    &outpos,
                    out_size.*,
                );

                out_size.* = outpos;

                if (err != 0) {
                    return c.SQFS_ERR;
                }

                return c.SQFS_OK;
            }
        }
else
    struct {};

usingnamespace if (build_options.enable_zlib)
    struct {
        extern fn libdeflate_zlib_decompress(
            *anyopaque,
            [*]const u8,
            usize,
            [*]u8,
            usize,
            *usize,
        ) c_int;

        // Deflate constants
        const litlen_syms = 288;
        const offset_syms = 32;
        const max_lens_overrun = 137;
        const max_num_syms = 288;
        const precode_syms = 19;

        // LibDeflate constants
        const precode_enough = 128;
        const litlen_enough = 2342;
        const offset_enough = 402;

        const Decompressor = extern struct {
            _: extern union {
                precode_lens: [precode_syms]u8,

                _: extern struct {
                    lens: [litlen_syms + offset_syms + max_lens_overrun]u8,
                    precode_table: [precode_enough]u32,
                },

                litlen_decode_table: [litlen_enough]u32,
            } = undefined,

            offset_decode_table: [offset_enough]u32 = undefined,
            sorted_syms: [max_num_syms]u16 = undefined,
            static_codes_loaded: bool = false,
            litlen_tablebits: u32 = undefined,
            free_func: ?*anyopaque = undefined,
        };

        export fn zig_zlib_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
            var decompressor = Decompressor{};

            const err = libdeflate_zlib_decompress(
                &decompressor,
                in,
                in_size,
                out,
                out_size.*,
                out_size,
            );

            if (err != 0) {
                return c.SQFS_ERR;
            }

            return c.SQFS_OK;
        }
    }
else
    struct {};

usingnamespace if (build_options.enable_lz4)
    struct {
        extern fn LZ4_decompress_safe(
            [*]const u8,
            [*]u8,
            c_int,
            c_int,
        ) c_int;

        export fn zig_lz4_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
            const ret = LZ4_decompress_safe(
                in,
                out,
                @intCast(in_size),
                @intCast(out_size.*),
            );

            if (ret < 0) {
                return c.SQFS_ERR;
            }

            out_size.* = @intCast(ret);

            return c.SQFS_OK;
        }
    }
else
    struct {};

usingnamespace if (build_options.enable_lzo)
    struct {
        extern fn lzo1x_decompress_safe(
            [*]const u8,
            u32,
            [*]u8,
            *u32,
            ?*anyopaque,
        ) u32;

        export fn zig_lzo_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
            const err = lzo1x_decompress_safe(
                in,
                @intCast(in_size),
                out,
                @ptrCast(out_size),
                null,
            );

            if (err != 0) {
                return c.SQFS_ERR;
            }

            return c.SQFS_OK;
        }
    }
else
    struct {};

usingnamespace if (build_options.enable_zstd)
    if (build_options.use_zig_zstd)
        struct {
            export fn zig_zstd_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                var stream = io.fixedBufferStream(in[0..in_size]);

                const allocator = std.heap.c_allocator;

                var decompressor = zstd.decompressStream(
                    allocator,
                    stream.reader(),
                );

                defer decompressor.deinit();

                const buf = out[0..out_size.*];

                out_size.* = decompressor.read(buf) catch return c.SQFS_ERR;

                return c.SQFS_OK;
            }
        }
    else
        struct {
            extern fn ZSTD_isError(usize) bool;
            extern fn ZSTD_decompress(
                [*]u8,
                usize,
                [*]const u8,
                usize,
            ) usize;

            export fn zig_zstd_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) c.sqfs_err {
                const ret = ZSTD_decompress(
                    out,
                    out_size.*,
                    in,
                    in_size,
                );

                if (ZSTD_isError(ret)) {
                    return c.SQFS_ERR;
                }

                out_size.* = ret;

                return c.SQFS_OK;
            }
        }
else
    struct {};

export fn noop() void {}
