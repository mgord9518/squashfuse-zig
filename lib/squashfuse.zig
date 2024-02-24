const std = @import("std");
const io = std.io;
const os = std.os;
const fs = std.fs;
const S = std.os.linux.S;

pub const build_options = @import("build_options");

const Cache = @import("Cache.zig");
const Table = @import("Table.zig");

const c = @cImport({
    @cInclude("squashfuse.h");

    @cInclude("swap.h");
    @cInclude("dir.h");
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
    arena2: std.heap.ArenaAllocator,
    internal: c.sqfs,
    version: std.SemanticVersion,
    file: fs.File,
    decompressFn: Decompressor,
    super_block: SuperBlock,

    id_table: Table,
    frag_table: Table,
    export_table: Table,
    xattr_id_table: Table,

    pub const magic: [4]u8 = "hsqs".*;

    pub const metadata_size = 8192;

    pub const invalid_xattr = 0xffffffff;
    pub const invalid_frag = 0xffffffff;
    pub const invalid_block = 0xffffffffffffffff;
    pub const meta_slots = 8;

    // TODO: multithreaded value
    pub const cached_blocks = 8;
    pub const data_cached_blocks = 1;
    pub const frag_cached_blocks = 3;
    //pub const cached_blocks = 128;
    //pub const data_cached_blocks = 48;
    //pub const frag_cached_blocks = 48;

    pub const compressed_bit = 1 << 15;
    pub const compressed_bit_block = 1 << 24;

    pub const supported_version = std.SemanticVersion{
        .major = 4,
        .minor = 0,
        .patch = 0,
    };

    pub const Decompressor = *const fn (
        allocator: std.mem.Allocator,
        in: []const u8,
        out: []u8,
    ) DecompressError!usize;

    pub const Compression = enum(u16) {
        zlib = 1,
        lzma = 2,
        lzo = 3,
        xz = 4,
        lz4 = 5,
        zstd = 6,
    };

    pub const SuperBlock = packed struct {
        magic: u32,
        inode_count: u32,
        modification_time: u32,
        block_size: u32,
        fragment_entry_count: u32,
        compression: Compression,
        //compression: u16,
        block_log: u16,
        flags: Flags,
        id_count: u16,
        version_major: u16,
        version_minor: u16,
        root_inode_id: u64,
        bytes_used: u64,
        id_table_start: u64,
        xattr_id_table_start: u64,
        inode_table_start: u64,
        directory_table_start: u64,
        fragment_table_start: u64,
        export_table_start: u64,

        pub const Flags = packed struct {
            uncompressed_inodes: bool,
            uncompressed_data: bool,

            // `check` flag; unused in SquashFS 4.0+
            UNUSED: u1,

            uncompressed_fragments: bool,
            no_fragments: bool,
            always_fragments: bool,
            duplicates: bool,
            exportable: bool,
            uncompressed_xattrs: bool,
            no_xattrs: bool,
            compressor_options: bool,
            uncompressed_idx: bool,

            UNUSED_2: u4,
        };
    };

    pub const FragmentEntry = extern struct {
        start_block: u64,
        size: u32,
        unused: u32,
    };

    pub const Options = struct {
        offset: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, opts: Options) !SquashFs {
        var sqfs = SquashFs{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .arena2 = std.heap.ArenaAllocator.init(allocator),
            .internal = undefined,
            .version = undefined,
            .file = try fs.cwd().openFile(path, .{}),
            .decompressFn = undefined,
            .super_block = undefined,
            .id_table = undefined,
            .frag_table = undefined,
            .export_table = undefined,
            .xattr_id_table = undefined,
        };

        // Populate internal squashfuse struct
        sqfs.internal = try initInternal(
            allocator,
            sqfs.arena.allocator(),
            sqfs.file.handle,
            opts.offset,
        );

        sqfs.internal.fd = sqfs.file.handle;
        sqfs.internal.offset = opts.offset;

        const sb_buf: [*]u8 = @ptrCast(&sqfs.super_block);
        if (try os.pread(sqfs.file.handle, sb_buf[0..@sizeOf(SuperBlock)], opts.offset) != @sizeOf(SuperBlock)) {
            return SquashFsError.InvalidFormat;
        }
        sqfs.super_block = littleToNative(sqfs.super_block);

        const magic_le32: u32 = @bitCast(SquashFs.magic);

        if (sqfs.super_block.magic != magic_le32) {
            if (sqfs.super_block.magic != @byteSwap(magic_le32)) {
                return SquashFsError.InvalidFormat;
            }

            sqfs.super_block.version_major = @byteSwap(sqfs.super_block.version_major);
            sqfs.super_block.version_minor = @byteSwap(sqfs.super_block.version_minor);
        }

        sqfs.id_table = try Table.init(
            allocator,
            sqfs.file.handle,
            @intCast(sqfs.super_block.id_table_start + opts.offset),
            4,
            sqfs.super_block.id_count,
        );

        sqfs.frag_table = try Table.init(
            allocator,
            sqfs.file.handle,
            @intCast(sqfs.super_block.fragment_table_start + opts.offset),
            @sizeOf(SquashFs.FragmentEntry),
            sqfs.super_block.fragment_entry_count,
        );

        if (sqfs.super_block.export_table_start != SquashFs.invalid_block) {
            sqfs.export_table = try Table.init(
                allocator,
                sqfs.file.handle,
                @intCast(sqfs.super_block.export_table_start + opts.offset),
                8,
                sqfs.super_block.inode_count,
            );
        }

        //try sqfs.XattrInit();

        sqfs.decompressFn = try getDecompressor(
            sqfs.super_block.compression,
        );

        // Set version
        sqfs.version = .{
            .major = sqfs.super_block.version_major,
            .minor = sqfs.super_block.version_minor,
            .patch = 0,
        };

        return sqfs;
    }

    pub fn deinit(sqfs: *SquashFs) void {
        Table.deinit(
            sqfs.allocator,
            &sqfs.id_table,
        );

        Table.deinit(
            sqfs.allocator,
            &sqfs.frag_table,
        );

        if (sqfs.internal.sb.lookup_table_start != SquashFs.invalid_block) {
            Table.deinit(
                sqfs.allocator,
                &sqfs.export_table,
            );
        }

        // Deinit caches
        sqfs.arena.deinit();

        sqfs.arena2.deinit();

        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: InodeId) !Inode {
        const allocator = sqfs.arena2.allocator();

        // TODO implement block dispose, fix memory leak
        const sqfs_inode = try getInodeFromId(
            allocator,
            sqfs,
            id,
        );

        const kind: SquashFs.File.Kind = if (sqfs_inode.base.inode_type <= 7) blk: {
            break :blk @enumFromInt(sqfs_inode.base.inode_type);
        } else blk: {
            break :blk @enumFromInt(sqfs_inode.base.inode_type - 7);
        };

        return Inode{
            .internal = sqfs_inode,
            .parent = sqfs,
            .kind = kind,
        };
    }

    fn TypeFromFileKind(comptime kind: SquashFs.File.InternalKind) type {
        return switch (kind) {
            .directory => c.squashfs_dir_inode,
            .file => c.squashfs_reg_inode,
            .sym_link => c.squashfs_symlink_inode,
            .block_device, .character_device => c.squashfs_dev_inode,
            .named_pipe, .unix_domain_socket => c.squashfs_ipc_inode,

            .l_directory => c.squashfs_ldir_inode,
            .l_file => c.squashfs_lreg_inode,
            .l_sym_link => c.squashfs_lsymlink_inode,
            .l_block_device, .l_character_device => c.squashfs_ldev_inode,
            .l_named_pipe, .l_unix_domain_socket => c.squashfs_lipc_inode,
        };
    }

    fn inodeType(
        comptime kind: SquashFs.File.InternalKind,
        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        inode: *c.sqfs_inode,
    ) !TypeFromFileKind(kind) {
        const T = TypeFromFileKind(kind);

        var x: T = undefined;

        try mdRead(
            allocator,
            sqfs,
            @ptrCast(&inode.next),
            @as([*]u8, @ptrCast(&x))[0..@sizeOf(T)],
        );

        return littleToNative(x);
    }

    fn getInodeFromId(
        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        id: u64,
    ) !c.sqfs_inode {
        var inode = std.mem.zeroes(c.sqfs_inode);

        inode.xattr = SquashFs.invalid_xattr;

        var cur = SquashFs.MdCursor.fromInodeId(
            id,
            sqfs.internal.sb.inode_table_start,
        );

        inode.next = @bitCast(cur);

        try mdRead(
            allocator,
            //sqfs.arena.allocator(),
            sqfs,
            @ptrCast(&cur),
            @as([*]u8, @ptrCast(&inode.base))[0..@sizeOf(@TypeOf(inode.base))],
        );

        inode.base = littleToNative(inode.base);

        const kind: SquashFs.File.InternalKind = @enumFromInt(inode.base.inode_type);

        inode.base.mode |= switch (kind) {
            .file, .l_file => S.IFREG,
            .directory, .l_directory => S.IFDIR,
            .sym_link, .l_sym_link => S.IFLNK,
            .block_device, .l_block_device => S.IFBLK,
            .character_device, .l_character_device => S.IFCHR,
            .named_pipe, .l_named_pipe => S.IFIFO,
            .unix_domain_socket, .l_unix_domain_socket => S.IFSOCK,
        };

        switch (kind) {
            .file => {
                const x = try inodeType(.file, allocator, sqfs, &inode);

                inode.nlink = 1;
                inode.xtra.reg.start_block = x.start_block;
                inode.xtra.reg.file_size = x.file_size;
                inode.xtra.reg.frag_idx = x.fragment;
                inode.xtra.reg.frag_off = x.offset;
            },
            .l_file => {
                const x = try inodeType(.l_file, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.reg.start_block = x.start_block;
                inode.xtra.reg.file_size = x.file_size;
                inode.xtra.reg.frag_idx = x.fragment;
                inode.xtra.reg.frag_off = x.offset;
                inode.xattr = x.xattr;
            },
            .directory => {
                const x = try inodeType(.directory, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.dir.start_block = x.start_block;
                inode.xtra.dir.offset = x.offset;
                inode.xtra.dir.dir_size = x.file_size;
                inode.xtra.dir.idx_count = 0;
                inode.xtra.dir.parent_inode = x.parent_inode;
            },
            .l_directory => {
                const x = try inodeType(.l_directory, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.dir.start_block = x.start_block;
                inode.xtra.dir.offset = x.offset;
                inode.xtra.dir.dir_size = x.file_size;
                inode.xtra.dir.idx_count = 0;
                inode.xtra.dir.parent_inode = x.parent_inode;
            },
            .sym_link, .l_sym_link => {
                const x = try inodeType(.sym_link, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.symlink_size = x.symlink_size;

                if (kind == .l_sym_link) {
                    cur = @bitCast(inode.next);
                    // TODO
                    //                try mdRead(sqfs, &cur, null, );
                }
            },
            .block_device, .character_device => {
                const x = try inodeType(.block_device, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.dev.major = @intCast((x.rdev >> 8) & 0xfff);
                inode.xtra.dev.minor = @intCast((x.rdev & 0xff) | (x.rdev >> 12) & 0xfff00);
            },
            .l_block_device, .l_character_device => {
                const x = try inodeType(.l_block_device, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xtra.dev.major = @intCast((x.rdev >> 8) & 0xfff);
                inode.xtra.dev.minor = @intCast((x.rdev & 0xff) | (x.rdev >> 12) & 0xfff00);
                inode.xattr = x.xattr;
            },
            .unix_domain_socket, .named_pipe => {
                const x = try inodeType(.named_pipe, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
            },
            .l_unix_domain_socket, .l_named_pipe => {
                const x = try inodeType(.l_named_pipe, allocator, sqfs, &inode);

                inode.nlink = @intCast(x.nlink);
                inode.xattr = @intCast(x.xattr);
            },
        }

        return inode;
    }

    pub inline fn getRootInode(sqfs: *SquashFs) Inode {
        return sqfs.getInode(
            sqfs.internal.sb.root_inode,
        ) catch unreachable;
    }

    fn fragEntry(sqfs: *SquashFs, frag: *FragmentEntry, idx: u32) !void {
        if (idx == SquashFs.invalid_frag) return error.Error;

        try Table.get(
            sqfs.arena2.allocator(),
            &sqfs.frag_table,
            sqfs,
            idx,
            @ptrCast(frag),
        );
    }

    fn dataCache(sqfs: *SquashFs, cache: *Cache, pos: usize, hdr: u32) !*Cache.Block {
        const allocator = sqfs.arena2.allocator();

        var entry = Cache.getCache(
            allocator,
            @ptrCast(@alignCast(cache)),
            pos,
        );

        if (!entry.isValid()) {
            entry.block = try dataBlockRead(
                allocator,
                sqfs,
                pos,
                hdr,
            );

            entry.markValid();
        }

        return entry.block;

        // TODO: sqfs_block_ref
    }

    pub fn mdCache(
        sqfs: *SquashFs,
        allocator: std.mem.Allocator,
        pos: *usize,
    ) !*Cache.Block {
        var entry = Cache.getCache(
            allocator,
            @ptrCast(&sqfs.internal.md_cache),
            @intCast(pos.*),
        );

        if (!entry.isValid()) {
            entry.data_size = try mdBlockRead(
                allocator,
                sqfs,
                pos.*,
                @ptrCast(&entry.block),
            );

            entry.markValid();
        }

        pos.* += @intCast(entry.data_size);

        return entry.block;
    }

    pub const Inode = struct {
        internal: c.sqfs_inode,
        parent: *SquashFs,
        kind: File.Kind,
        pos: u64 = 0,

        fn fragBlock(
            inode: *Inode,
            offset: *usize,
            size: *usize,
        ) !*Cache.Block {
            var sqfs = inode.parent;
            var block: *Cache.Block = undefined;

            var frag: FragmentEntry = undefined;

            if (inode.kind != .file) return error.Error;

            try sqfs.fragEntry(
                &frag,
                inode.internal.xtra.reg.frag_idx,
            );

            block = try sqfs.dataCache(
                @ptrCast(&sqfs.internal.frag_cache),
                @intCast(frag.start_block),
                frag.size,
            );

            offset.* = inode.internal.xtra.reg.frag_off;
            size.* = inode.internal.xtra.reg.file_size % sqfs.internal.sb.block_size;

            return block;
        }

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
                @ptrCast(&cur),
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
            if (self.kind != .file) {
                return SquashFsError.NotRegularFile;
            }

            const buf_len = try readRange(
                self.parent,
                self,
                @intCast(self.pos),
                buf,
            );

            self.pos += buf_len;

            return buf_len;
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
            var id: [4]u8 = undefined;

            try Table.get(
                sqfs.allocator,
                &sqfs.id_table,
                sqfs,
                idx,
                &id,
            );

            return std.mem.littleToNative(
                u32,
                @bitCast(id),
            );
        }

        pub inline fn stat(inode: *Inode) !fs.File.Stat {
            return fs.File.Stat.fromSystem(
                try inode.statC(),
            );
        }

        inline fn makeDev(major: u32, minor: u32) u64 {
            const min64: u64 = minor;
            const maj64: u64 = major;

            const min0 = (min64 & 0x000000ff);
            const min1 = (min64 & 0xffffff00) << 12;

            const maj0 = (maj64 & 0x00000fff) << 8;
            const maj1 = (maj64 & 0xfffff000) << 32;

            return (min0 | min1 | maj0 | maj1);
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
                    st.rdev = makeDev(
                        @intCast(inode.internal.xtra.dev.major),
                        @intCast(inode.internal.xtra.dev.minor),
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
            const dir = try Dir.open(
                self.parent,
                self,
            );

            return .{
                .dir = self.*,
                .internal = dir,
                .parent = self.parent,
            };
        }

        pub const Iterator = struct {
            dir: Inode,
            internal: SquashFs.Dir,
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

            /// Returns an entry for the next inode in the directory
            pub fn next(self: *Iterator) !?Entry {
                var sqfs_dir_entry: SquashFs.Dir.Entry = undefined;

                sqfs_dir_entry.name = &self.name_buf;

                const found = try Dir.dirNext(
                    self.dir.parent.arena.allocator(),
                    self.parent,
                    &self.internal,
                    &sqfs_dir_entry,
                );

                if (!found) return null;

                // Append null byte
                self.name_buf[sqfs_dir_entry.name_len] = '\x00';

                return .{
                    .id = sqfs_dir_entry.inode,
                    .name = self.name_buf[0..sqfs_dir_entry.name_len :0],
                    .kind = @enumFromInt(sqfs_dir_entry.kind),
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
        pub const Kind = enum(u3) {
            directory = 1,
            file = 2,
            sym_link = 3,
            block_device = 4,
            character_device = 5,
            named_pipe = 6,
            unix_domain_socket = 7,
        };

        pub const InternalKind = enum(u4) {
            directory = 1,
            file = 2,
            sym_link = 3,
            block_device = 4,
            character_device = 5,
            named_pipe = 6,
            unix_domain_socket = 7,

            // `long` versions of the types, which contain additional info
            l_directory = 8,
            l_file = 9,
            l_sym_link = 10,
            l_block_device = 11,
            l_character_device = 12,
            l_named_pipe = 13,
            l_unix_domain_socket = 14,
        };
    };

    pub const Dir = @import("Dir.zig");

    pub const MdCursor = extern struct {
        block: u64,
        offset: usize,

        pub fn fromInodeId(id: u64, base: u64) MdCursor {
            return .{
                .block = @intCast((id >> 16) + base),
                .offset = id & 0xffff,
            };
        }
    };

    pub const XattrId = packed struct {
        xattr: u64,
        count: u32,
        size: u32,
    };

    pub fn XattrInit(sqfs: *SquashFs) !void {
        var start = sqfs.super_block.xattr_id_table_start;
        _ = &start;

        if (start == SquashFs.invalid_block) return;

        const xattr_u8: [*]u8 = @ptrCast(&sqfs.internal.xattr_info);
        const xattr_size = @sizeOf(@TypeOf(sqfs.internal.xattr_info));
        if (try os.pread(
            sqfs.internal.fd,
            xattr_u8[0..xattr_size],
            start + sqfs.internal.offset,
        ) != xattr_size) {
            return error.ReadFailed;
        }

        sqfs.internal.xattr_info = littleToNative(sqfs.internal.xattr_info);

        sqfs.internal.xattr_table = @bitCast(try Table.init(
            sqfs.allocator,
            sqfs.internal.fd,
            @intCast(start + xattr_size + sqfs.internal.offset),
            @sizeOf(XattrId),
            sqfs.internal.xattr_info.xattr_ids,
        ));
    }

    //    pub fn fragEntry(sqfs: *SquashFs, )
};

// TODO: type safety
/// Load data directly from image into a structure
pub fn load(fd: i32, slice: anytype, offset: u64) !void {
    const T = @TypeOf(slice.ptr);
    const size = @sizeOf(@typeInfo(T).Pointer.child);
    const item_u8: [*]u8 = @ptrCast(slice.ptr);

    if (try os.pread(
        fd,
        item_u8[0 .. size * slice.len],
        offset,
    ) != size * slice.len) {
        return error.PartialRead;
    }
}

fn readRange(
    sqfs: *SquashFs,
    inode: *SquashFs.Inode,
    start: usize,
    //obuf: [*]u8,
    obuf: []u8,
) !usize {
    var buf = obuf.ptr;
    var size = obuf.len;

    if (inode.kind != .file) return SquashFsError.Error;

    const file_size = inode.internal.xtra.reg.file_size;
    const block_size = sqfs.internal.sb.block_size;

    if (size < 0 or start > file_size) return SquashFsError.Error;

    if (start == file_size) {
        size = 0;
        return 0;
    }

    var bl: c.sqfs_blocklist = undefined;
    try SquashFsErrorFromInt(c.sqfs_blockidx_blocklist(
        &sqfs.internal,
        &inode.internal,
        &bl,
        @intCast(start),
    ));

    var read_off = start % block_size;
    const buf_orig = buf;

    while (size > 0) {
        var block: ?*Cache.Block = null;
        var data_off: usize = 0;
        var data_size: usize = 0;
        var take: usize = 0;

        const fragment = bl.remain == 0;
        if (fragment) {
            if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) break;

            //            try SquashFsErrorFromInt(c.sqfs_frag_block(
            //                &sqfs.internal,
            //                &inode.internal,
            //                &data_off,
            //                &data_size,
            //                @ptrCast(&block),
            //            ));

            block = try inode.fragBlock(
                &data_off,
                &data_size,
            );
        } else {
            try SquashFsErrorFromInt(c.sqfs_blocklist_next(&bl));

            if (bl.pos + block_size <= start) continue;

            data_off = 0;
            if (bl.input_size == 0) {
                data_size = file_size - bl.pos;

                if (data_size > block_size) data_size = block_size;
            } else {
                try SquashFsErrorFromInt(c.sqfs_data_cache(
                    &sqfs.internal,
                    &sqfs.internal.data_cache,
                    @intCast(bl.block),
                    bl.header,
                    @ptrCast(&block),
                ));

                data_size = block.?.size;
            }
        }

        take = data_size - read_off;
        if (take > size) take = size;

        if (block != null) {
            @memcpy(buf[0..take], block.?.data[data_off + read_off ..][0..take]);
        } else {
            @memset(buf[0..take], 0);
        }

        read_off = 0;
        size -= take;
        buf = buf + take;

        if (fragment) break;
    }

    size = @intFromPtr(buf - @intFromPtr(buf_orig));
    return if (size != 0) size else error.Error;
}

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

const sqfs_cache_entry_hdr = extern struct {
    valid: bool,
    idx: c.sqfs_cache_idx,
};

fn cacheEntryValid(e: *c.sqfs_block_cache_entry) bool {
    var hdr: [*]sqfs_cache_entry_hdr = @ptrCast(@alignCast(e));
    hdr -= 1;

    return hdr[0].valid;
}

fn dataBlockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    hdr_le: u32,
) !*Cache.Block {
    //var compressed = false;
    //var size: u32 = 0;

    const size = hdr_le & ~@as(u32, SquashFs.compressed_bit_block);
    //
    const compressed = hdr_le & SquashFs.compressed_bit_block == 0;

    //c.sqfs_data_header(hdr, &compressed, &size);

    return blockRead(
        allocator,
        sqfs,
        pos,
        compressed,
        size,
        sqfs.internal.sb.block_size,
    );
}

fn blockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    compressed: bool,
    size: u32,
    out_size: usize,
) !*Cache.Block {
    var block = try allocator.create(Cache.Block);

    block.refcount = 1;

    block.data = (try allocator.alloc(u8, size)).ptr;

    var written = out_size;

    try load(
        sqfs.file.handle,
        block.data[0..size],
        pos + sqfs.internal.offset,
    );

    if (compressed) {
        const decomp = try allocator.alloc(u8, out_size);

        if (true) {
            written = sqfs.decompressFn(
                allocator,
                @as([*]u8, @ptrCast(block.data))[0..size],
                decomp[0..out_size],
            ) catch blk: {
                allocator.free(decomp);
                break :blk 0;
            };
        } else {
            const err = sqfs.internal.decompressor.?(
                block.data,
                size,
                decomp.ptr,
                &written,
            );
            if (err != 0) {
                // TODO: free block
                //      allocator.free(decomp);
            }
        }

        allocator.free(@as([*]u8, @ptrCast(block.data))[0..size]);
        block.data = decomp.ptr;
        block.size = written;
    } else {
        block.size = size;
    }

    return block;
}

pub fn mdBlockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    block: **Cache.Block,
) !usize {
    var hdr: [2]u8 = undefined;

    try load(
        sqfs.file.handle,
        &hdr,
        pos + sqfs.internal.offset,
    );

    const hdr_le = std.mem.littleToNative(
        u16,
        @bitCast(hdr),
    );

    var size = hdr_le & ~@as(u16, SquashFs.compressed_bit);

    if (size == 0) {
        size = SquashFs.compressed_bit;
    }

    const compressed = hdr_le & SquashFs.compressed_bit == 0;

    block.* = try blockRead(
        allocator,
        sqfs,
        pos + hdr.len,
        compressed,
        size,
        SquashFs.metadata_size,
    );

    return size + hdr.len;
}

pub fn mdRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    cur: *SquashFs.MdCursor,
    buf: []u8,
) !void {
    var pos = cur.block;

    var size = buf.len;
    var nbuf = buf;

    while (size > 0) {
        const block = try sqfs.mdCache(allocator, @ptrCast(&pos));

        var take = block.size - cur.offset;
        if (take > size) {
            take = size;
        }

        const data_slice: [*]u8 = @ptrCast(block.data);
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

// TODO: refactor, move into the main init method
fn initInternal(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    fd: i32,
    offset: usize,
) !c.sqfs {
    _ = allocator;
    var sqfs = std.mem.zeroes(c.sqfs);
    _ = offset;

    // Swap endianness if necessary
    sqfs.sb = littleToNative(sqfs.sb);

    const SqfsSb = @TypeOf(sqfs.sb);

    const sb_buf: [*]u8 = @ptrCast(&sqfs.sb);
    if (try os.pread(fd, sb_buf[0..@sizeOf(SqfsSb)], @intCast(sqfs.offset)) != @sizeOf(SqfsSb)) {
        return SquashFsError.InvalidFormat;
    }

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

    // TODO: clean up memory if fail
    sqfs.md_cache = @ptrCast(try Cache.BlockCacheEntry.init(arena, SquashFs.cached_blocks));
    sqfs.data_cache = @ptrCast(try Cache.BlockCacheEntry.init(arena, SquashFs.data_cached_blocks));
    sqfs.frag_cache = @ptrCast(try Cache.BlockCacheEntry.init(arena, SquashFs.frag_cached_blocks));

    sqfs.blockidx = @ptrCast(try Cache.BlockIdx.init(arena));

    return sqfs;
}

fn initBlockIdx(allocator: std.mem.Allocator, ch: *c.sqfs_cache) !void {
    try Cache.initCache(
        allocator,
        ch,
        @sizeOf(**c.sqfs_blockidx_entry),
        SquashFs.meta_slots,
        @ptrCast(&noop),
        //&c.sqfs_block_cache_dispose,
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

pub fn littleToNative(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);

    return @bitCast(
        std.mem.littleToNative(
            @Type(.{ .Int = .{
                .signedness = .unsigned,
                .bits = @bitSizeOf(T),
            } }),
            @bitCast(x),
        ),
    );
}

export fn noop() void {}
