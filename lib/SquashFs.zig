const std = @import("std");
const io = std.io;
const os = std.os;
const fs = std.fs;
const cache = @import("cache.zig");

pub const build_options = @import("build_options");

const Table = @import("Table.zig");

const c = @cImport({
    @cInclude("squashfuse.h");

    @cInclude("swap.h");
    @cInclude("nonstd.h");
});

pub const SquashFsError = error{
    Error,
    InvalidFormat,
    InvalidVersion,
    InvalidCompression,
    UnsupportedFeature,
    NotRegularFile,
};

// TODO
pub const DecompressError = error{
    Error,
    // TODO: rename these to zig stdlib conventions
    BadData,
    NoSpaceLeft,
    ShortOutput,
    OutOfMemory,
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
    decompressFn: Decompressor,

    pub const magic: [4]u8 = "hsqs".*;

    pub const metadata_size = 8192;

    pub const invalid_xattr = 0xffffffff;
    pub const invalid_frag = 0xffffffff;
    pub const invalid_block = -1;
    pub const meta_slots = 8;

    // TODO: multithreaded value
    pub const cached_blocks = 8;
    pub const data_cached_blocks = 1;
    pub const frag_cached_blocks = 3;
    //pub const cached_blocks = 128;
    //pub const data_cached_blocks = 48;
    //pub const frag_cached_blocks = 48;

    const supported_version = std.SemanticVersion{
        .major = 4,
        .minor = 0,
        .patch = 0,
    };

    pub const Decompressor = *const fn (
        allocator: std.mem.Allocator,
        in: []const u8,
        out: []u8,
    ) DecompressError!usize;

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
            .decompressFn = undefined,
        };

        // Populate internal squashfuse struct
        try initInternal(
            allocator,
            sqfs.arena.allocator(),
            &sqfs.internal,
            sqfs.file.handle,
            opts.offset,
        );

        sqfs.decompressFn = try getDecompressor(@enumFromInt(sqfs.internal.sb.compression));

        // Set version
        sqfs.version = .{
            .major = @intCast(sqfs.internal.sb.s_major),
            .minor = @intCast(sqfs.internal.sb.s_minor),
            .patch = 0,
        };

        return sqfs;
    }

    pub fn deinit(sqfs: *SquashFs) void {
        Table.deinit(
            sqfs.allocator,
            @ptrCast(&sqfs.internal.id_table),
            sqfs.internal.sb.no_ids,
        );

        Table.deinit(
            sqfs.allocator,
            @ptrCast(&sqfs.internal.frag_table),
            sqfs.internal.sb.fragments,
        );

        if (sqfs.internal.sb.lookup_table_start != SquashFs.invalid_block) {
            Table.deinit(
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

        var arena = std.heap.ArenaAllocator.init(sqfs.allocator);
        defer arena.deinit();

        try getInodeFromId(
            arena.allocator(),
            sqfs,
            &sqfs_inode,
            id,
        );

        return Inode{
            .internal = sqfs_inode,
            .parent = sqfs,
            .kind = @enumFromInt(sqfs_inode.base.inode_type),
        };
    }

    fn getInodeFromId(allocator: std.mem.Allocator, sqfs: *SquashFs, inode: *c.sqfs_inode, id: c.sqfs_inode_id) !void {
        inode.* = std.mem.zeroes(c.sqfs_inode);
        var cur: c.sqfs_md_cursor = undefined;

        inode.xattr = SquashFs.invalid_xattr;

        c.sqfs_md_cursor_inode(&cur, id, @intCast(sqfs.internal.sb.inode_table_start));
        inode.next = cur;

        try mdRead(
            sqfs.arena.allocator(),
            sqfs,
            &cur,
            @as([*]u8, @ptrCast(&inode.base))[0..@sizeOf(@TypeOf(inode.base))],
        );

        c.sqfs_swapin_base_inode(&inode.base);

        inode.base.mode |= @intCast(c.sqfs_mode(inode.base.inode_type));

        const kind: SquashFs.File.Kind = @enumFromInt(inode.base.inode_type);

        switch (kind) {
            .file => {
                //INODE_TYPE
                var x: c.squashfs_reg_inode = undefined;
                try mdRead(
                    allocator,
                    sqfs,
                    &inode.next,
                    @as([*]u8, @ptrCast(&x))[0..@sizeOf(c.squashfs_reg_inode)],
                );
                c.sqfs_swapin_reg_inode(&x);
                //INODE_TYPE
                inode.nlink = 1;
                inode.xtra.reg.start_block = x.start_block;
                inode.xtra.reg.file_size = x.file_size;
                inode.xtra.reg.frag_idx = x.fragment;
                inode.xtra.reg.frag_off = x.offset;
            },
            .l_file => {
                //INODE_TYPE
                var x: c.squashfs_lreg_inode = undefined;
                try mdRead(
                    allocator,
                    sqfs,
                    &inode.next,
                    @as([*]u8, @ptrCast(&x))[0..@sizeOf(c.squashfs_lreg_inode)],
                );
                c.sqfs_swapin_lreg_inode(&x);
                //INODE_TYPE
                inode.nlink = 1;
                inode.xtra.reg.start_block = x.start_block;
                inode.xtra.reg.file_size = x.file_size;
                inode.xtra.reg.frag_idx = x.fragment;
                inode.xtra.reg.frag_off = x.offset;
                inode.xattr = x.xattr;
            },
            .directory => {
                //INODE_TYPE
                var x: c.squashfs_dir_inode = undefined;
                try mdRead(
                    allocator,
                    sqfs,
                    &inode.next,
                    @as([*]u8, @ptrCast(&x))[0..@sizeOf(c.squashfs_dir_inode)],
                );
                c.sqfs_swapin_dir_inode(&x);
                //INODE_TYPE
                inode.nlink = @intCast(x.nlink);
                inode.xtra.dir.start_block = x.start_block;
                inode.xtra.dir.offset = x.offset;
                inode.xtra.dir.dir_size = x.file_size;
                inode.xtra.dir.idx_count = 0;
                inode.xtra.dir.parent_inode = x.parent_inode;
            },
            else => {},
            .sym_link, .l_sym_link => {
                //INODE_TYPE
                var x: c.squashfs_symlink_inode = undefined;
                try mdRead(
                    allocator,
                    sqfs,
                    &inode.next,
                    @as([*]u8, @ptrCast(&x))[0..@sizeOf(c.squashfs_symlink_inode)],
                );
                c.sqfs_swapin_symlink_inode(&x);
                //INODE_TYPE
                inode.nlink = @intCast(x.nlink);
                inode.xtra.symlink_size = x.symlink_size;

                if (kind == .l_sym_link) {
                    cur = inode.next;
                    // TODO
                    //                try mdRead(sqfs, &cur, null, );
                }
            },
        }
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

            if (len > buf.len - 1) {
                return error.NoSpaceLeft;
            }

            var cur = inode.internal.next;

            try mdRead(
                inode.parent.arena.allocator(),
                inode.parent,
                &cur,
                buf[0..len],
            );

            return buf[0..len];
        }

        pub fn readLinkZ(self: *Inode, buf: []u8) ![:0]const u8 {
            const link_target = try self.readLink(buf[0 .. buf.len - 1]);
            buf[link_target.len] = '\x00';

            return buf[0..link_target.len :0];
        }

        /// Wrapper of `sqfs_read_range`
        /// Use for reading one byte buffer at a time
        /// Retruns the amount of bytes read
        pub fn read(self: *Inode, buf: []u8) !usize {
            if (self.kind != .file and self.kind != .l_file) {
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

        fn getId(sqfs: *SquashFs, idx: u16) !u32 {
            var id: u32 = 0;

            try SquashFsErrorFromInt(c.sqfs_table_get(
                &sqfs.internal.id_table,
                &sqfs.internal,
                idx,
                &id,
            ));

            return std.mem.littleToNative(
                u32,
                id,
            );
        }

        pub inline fn stat(inode: *Inode) !fs.File.Stat {
            return fs.File.Stat.fromSystem(
                try inode.statC(),
            );
        }

        // Like `Inode.stat` but returns the OS native stat format
        pub fn statC(inode: *Inode) !os.Stat {
            var st = std.mem.zeroes(os.Stat);

            st.mode = inode.internal.base.mode;
            st.nlink = @intCast(inode.internal.nlink);

            st.atim.tv_sec = @intCast(inode.internal.base.mtime);
            st.ctim.tv_sec = @intCast(inode.internal.base.mtime);
            st.mtim.tv_sec = @intCast(inode.internal.base.mtime);

            switch (inode.kind) {
                .file => {
                    st.size = @intCast(inode.internal.xtra.reg.file_size);
                    st.blocks = @divTrunc(st.size, 512);
                },
                .block_device, .character_device => {
                    st.rdev = c.sqfs_makedev(
                        inode.internal.xtra.dev.major,
                        inode.internal.xtra.dev.minor,
                    );
                },
                .sym_link => {
                    st.size = @intCast(inode.internal.xtra.symlink_size);
                },
                else => {},
            }

            st.blksize = @intCast(inode.parent.internal.sb.block_size);

            st.uid = @intCast(inode.parent.internal.uid);
            if (st.uid == 0) {
                st.uid = try getId(inode.parent, inode.internal.base.uid);
            }

            st.gid = @intCast(inode.parent.internal.gid);
            if (st.gid == 0) {
                st.gid = try getId(inode.parent, inode.internal.base.guid);
            }

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
                    // This should never fail
                    // if it does, something went very wrong (like messing with
                    // the inode ID)
                    return getInode(
                        self.parent,
                        self.id,
                    ) catch unreachable;
                }
            };

            /// Wraps `sqfs_dir_next`
            /// Returns an entry for the next inode in the directory
            pub fn next(self: *Iterator) !?Entry {
                var sqfs_dir_entry: c.sqfs_dir_entry = undefined;

                sqfs_dir_entry.name = &self.name_buf;

                const found = try dirNext(
                    self.dir.parent.arena.allocator(),
                    self.parent,
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
                    return getInode(
                        self.parent,
                        self.id,
                    ) catch unreachable;
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

//fn readRange(sqfs: *SquashFs, inode: *Inode, start: c.sqfs_off_t, size: *c.sqfs_off_t, buf: *anyopaque,) !void {
//    var file_size: c.sqfs_off_t = undefined;
//    var block_size: usize = 0;
//    var bl: c.sqfs_blocklist = undefined;
//
//    var read_off: usize = 0;
//    var buf_orig: [*]u8;
//
//    if (inode.kind != .file) return SquashFsError.Error;
//
//    file_size = inode.internal.xtra.reg.file_size;
//    block_size = sqfs.internal.sb.block_size;
//
//    if (size.* < 0 or start > file_size) return SquashFsError.Error;
//
//    if (start == file_size) {
//        size.* = 0;
//        return;
//    }
//
//
//
//}

pub fn getDecompressor(kind: SquashFs.Compression) SquashFsError!SquashFs.Decompressor {
    switch (kind) {
        .zlib => {
            if (comptime build_options.enable_zlib) return algos.zlibDecode;
        },
        .lzma => {},
        .xz => {
            if (comptime build_options.enable_xz) return algos.xzDecode;
        },
        .lzo => {
            if (comptime build_options.enable_lzo) return algos.lzoDecode;
        },
        .lz4 => {
            if (comptime build_options.enable_lz4) return algos.lz4Decode;
        },
        .zstd => {
            if (comptime build_options.enable_zstd) return algos.zstdDecode;
        },
    }

    return error.InvalidCompression;
}

export fn sqfs_decompressor_get(kind: SquashFs.Compression) ?*const fn ([*]u8, usize, [*]u8, *usize) callconv(.C) c.sqfs_err {
    return switch (kind) {
        .zlib => algos.getLibsquashfuseDecompressionFn(.zlib),
        .lzma => algos.getLibsquashfuseDecompressionFn(.lzma),
        .xz => algos.getLibsquashfuseDecompressionFn(.xz),
        .lzo => algos.getLibsquashfuseDecompressionFn(.lzo),
        .lz4 => algos.getLibsquashfuseDecompressionFn(.lz4),
        .zstd => algos.getLibsquashfuseDecompressionFn(.zstd),
    };
}

fn dirMdRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    dir: *c.sqfs_dir,
    buf: []u8,
) !void {
    dir.offset += @intCast(buf.len);

    //try SquashFsErrorFromInt(c.sqfs_md_read(sqfs, &dir.cur, buf.ptr, buf.len));

    try mdRead(allocator, sqfs, &dir.cur, buf);
}

const sqfs_cache_entry_hdr = extern struct {
    valid: bool,
    idx: c.sqfs_cache_idx,
};

fn cacheEntryValid(e: *c.sqfs_block_cache_entry) bool {
    var hdr: [*]sqfs_cache_entry_hdr = @ptrCast(@alignCast(e));
    hdr -= 1;

    return hdr[0].valid;
}

//fn mdHeader(hdr: u16, compressed: *bool, size: *u16) void {
//    compressed.* = (hdr & c.SQUASHFS_COMPRESSED_BIT) == 0;
//    size.* = hdr & @as(u16, @truncate(@as(u32, @bitCast(-c.SQUASHFS_COMPRESSED_BIT))));
//
//    if (size.* == 0) {
//        size.* = c.SQUASHFS_COMPRESSED_BIT;
//    }
//}

fn blockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    compressed: bool,
    size: u32,
    out_size: usize,
    block: **c.sqfs_block,
) !void {
    block.* = try allocator.create(c.sqfs_block);

    block.*.refcount = 1;

    block.*.data = (try allocator.alloc(u8, size)).ptr;

    var written = out_size;

    const data_u8: [*]u8 = @ptrCast(block.*.data.?);
    if (try os.pread(sqfs.internal.fd, data_u8[0..size], pos + sqfs.internal.offset) != size) {
        // TODO: free block
    }

    if (compressed) {
        const decomp = try allocator.alloc(u8, out_size);

        if (true) {
            written = sqfs.decompressFn(allocator, @as([*]u8, @ptrCast(block.*.data))[0..size], decomp[0..out_size]) catch blk: {
                allocator.free(decomp);
                break :blk 0;
            };
        } else {
            std.debug.print("READ\n", .{});
            const err = sqfs.internal.decompressor.?(block.*.data, size, decomp.ptr, &written);
            if (err != 0) {
                // TODO: free block
                allocator.free(decomp);
            }
            std.debug.print("READ2\n", .{});
        }

        //        allocator.free(@as([*]u8, @ptrCast(block.*.data))[0..size]);
        block.*.data = decomp.ptr;
        block.*.size = written;
    } else {
        block.*.size = size;
    }
}

pub fn mdBlockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    data_size: *usize,
    block: **c.sqfs_block,
) !void {
    data_size.* = 0;

    var hdr: [2]u8 = undefined;
    var compressed: bool = undefined;
    var size: u16 = undefined;
    var npos = pos;

    if (try os.pread(sqfs.internal.fd, &hdr, npos + sqfs.internal.offset) != 2) {
        // TODO error
        unreachable;
    }

    npos += 2;
    data_size.* += 2;

    const hdr_le = std.mem.littleToNative(
        u16,
        @bitCast(hdr),
    );

    c.sqfs_md_header(hdr_le, &compressed, &size);
    //mdHeader(hdr_le, &compressed, &size);

    //try SquashFsErrorFromInt(c.sqfs_block_read(
    try blockRead(
        allocator,
        sqfs,
        @intCast(npos),
        compressed,
        size,
        SquashFs.metadata_size,
        @ptrCast(block),
    );

    data_size.* += size;
}

fn mdRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    cur: *c.sqfs_md_cursor,
    buf: []u8,
) !void {
    var pos = cur.block;

    var size = buf.len;
    var nbuf = buf;

    while (size > 0) {
        var block: *c.sqfs_block = undefined;

        //        try SquashFsErrorFromInt(
        //            c.sqfs_md_cache(sqfs, &pos, &block),
        //        );
        try cache.mdCache(allocator, sqfs, @ptrCast(&pos), @ptrCast(&block));

        var take = block.size - cur.offset;
        if (take > size) {
            take = size;
        }

        const data_slice: [*]u8 = @ptrCast(block.data.?);
        @memcpy(
            nbuf[0..take],
            (data_slice + cur.offset)[0..take],
        );

        nbuf = nbuf[take..];

        size -= take;
        cur.offset += take;

        if (cur.offset == block.size) {
            cur.block = pos;
            cur.offset = 0;
        }
    }
}

fn dirNext(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    dir: *c.sqfs_dir,
    entry: *c.sqfs_dir_entry,
) !bool {
    var e: c.squashfs_dir_entry = undefined;

    entry.offset = dir.offset;

    while (dir.header.count == 0) {
        if (dir.offset >= dir.total) {
            return false;
        }

        const header_slice: []u8 = @as([*]u8, @ptrCast(&dir.header))[0..@sizeOf(@TypeOf(dir.header))];
        try dirMdRead(allocator, sqfs, dir, header_slice);

        dir.header = @bitCast(
            std.mem.littleToNative(
                u96,
                @bitCast(dir.header),
            ),
        );

        //        c.sqfs_swapin_dir_header(&dir.header);
        dir.header.count += 1;
    }

    const e_slice: []u8 = @as([*]u8, @ptrCast(&e))[0..@sizeOf(@TypeOf(e))];
    try dirMdRead(allocator, sqfs, dir, e_slice);

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

    const entry_slice: []u8 = @as([*]u8, @ptrCast(entry.name))[0..entry.name_size];

    try dirMdRead(allocator, sqfs, dir, entry_slice);

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
    sqfs.* = std.mem.zeroes(c.sqfs);

    sqfs.fd = fd;
    sqfs.offset = offset;

    const SqfsSb = @TypeOf(sqfs.sb);

    //if (c.sqfs_pread(fd, &sqfs.sb, @sizeOf(SqfsSb), @intCast(sqfs.offset)) != @sizeOf(SqfsSb)) {
    const sb_buf: [*]u8 = @ptrCast(&sqfs.sb);
    if (try os.pread(fd, sb_buf[0..@sizeOf(SqfsSb)], @intCast(sqfs.offset)) != @sizeOf(SqfsSb)) {
        return SquashFsError.InvalidFormat;
    }

    // Swap endianness if necessary
    sqfs.sb = @bitCast(
        std.mem.littleToNative(
            u768,
            @bitCast(sqfs.sb),
        ),
    );

    const magic_le32: u32 = @bitCast(SquashFs.magic);

    if (sqfs.sb.s_magic != magic_le32) {
        if (sqfs.sb.s_magic != @byteSwap(magic_le32)) {
            return SquashFsError.InvalidFormat;
        }

        sqfs.sb.s_major = @byteSwap(sqfs.sb.s_major);
        sqfs.sb.s_minor = @byteSwap(sqfs.sb.s_minor);
    }

    if (sqfs.sb.s_major != SquashFs.supported_version.major or sqfs.sb.s_minor > SquashFs.supported_version.minor) {
        return SquashFsError.InvalidVersion;
    }

    // TODO: find and replace functions using decompressor
    sqfs.decompressor = @ptrCast(sqfs_decompressor_get(@enumFromInt(sqfs.sb.compression)));
    //sqfs.decompressor = @ptrCast(&noop);
    if (sqfs.decompressor == null) {
        return SquashFsError.InvalidCompression;
    }

    sqfs.id_table = @bitCast(try Table.init(
        allocator,
        fd,
        @intCast(sqfs.sb.id_table_start + sqfs.offset),
        4,
        sqfs.sb.no_ids,
    ));

    sqfs.frag_table = @bitCast(try Table.init(
        allocator,
        fd,
        @intCast(sqfs.sb.fragment_table_start + sqfs.offset),
        @sizeOf(c.squashfs_fragment_entry),
        sqfs.sb.fragments,
    ));

    if (sqfs.sb.lookup_table_start != SquashFs.invalid_block) {
        sqfs.export_table = @bitCast(try Table.init(
            allocator,
            fd,
            @intCast(sqfs.sb.lookup_table_start + sqfs.offset),
            8,
            sqfs.sb.inodes,
        ));
    }

    //try SquashFsErrorFromInt(c.sqfs_xattr_init(sqfs));

    // TODO: clean up memory if fail
    sqfs.md_cache = @ptrCast(try cache.BlockCacheEntry.init(arena, SquashFs.cached_blocks));
    sqfs.data_cache = @ptrCast(try cache.BlockCacheEntry.init(arena, SquashFs.data_cached_blocks));
    sqfs.frag_cache = @ptrCast(try cache.BlockCacheEntry.init(arena, SquashFs.frag_cached_blocks));

    sqfs.blockidx = @ptrCast(try cache.BlockIdx.init(arena));
}

fn initBlockIdx(allocator: std.mem.Allocator, ch: *c.sqfs_cache) !void {
    try cache.initCache(
        allocator,
        ch,
        @sizeOf(**c.sqfs_blockidx_entry),
        SquashFs.meta_slots,
        @ptrCast(&noop),
    );
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
const algos = @import("algos.zig");

export fn noop() void {}
