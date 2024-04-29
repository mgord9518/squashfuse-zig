const std = @import("std");
const io = std.io;
const os = std.os;
const posix = std.posix;
const fs = std.fs;

pub const build_options = @import("build_options");

const Cache = @import("Cache.zig");
const Table = @import("Table.zig");

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

/// Top-level SquashFS object; should fully implement std.fs.Dir functionality
pub const SquashFs = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    arena2: std.heap.ArenaAllocator,
    version: std.SemanticVersion,
    file: fs.File,
    decompressFn: Decompressor,
    super_block: SuperBlock,

    id_table: Table,
    frag_table: Table,
    export_table: ?Table,
    xattr_table: Table,

    blockidx: *Cache,
    md_cache: *Cache,
    data_cache: *Cache,
    frag_cache: *Cache,

    xattr_info: XattrIdTable,

    offset: u64,

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

        pub const InodeBase = extern struct {
            //kind: File.InternalKind,
            //UNUSED: u12 = 0,
            kind: u16,
            mode: u16,
            uid: u16,
            guid: u16,
            mtime: u32,
            inode_number: u32,
        };

        pub const DirInode = extern struct {
            base: InodeBase,
            start_block: u32,
            nlink: u32,
            size: u16,
            offset: u16,
            parent_inode: u32,

            pub fn toLong(inode: DirInode) LDirInode {
                return .{
                    .start_block = inode.start_block,
                    .offset = inode.offset,
                    .size = inode.size,
                    .i_count = 0,
                    .nlink = inode.nlink,
                    .xattr = SquashFs.invalid_xattr,
                    .base = inode.base,
                    .parent_inode = inode.parent_inode,
                };
            }
        };

        pub const FileInode = extern struct {
            base: InodeBase,
            start_block: u32,
            frag_idx: u32,
            frag_off: u32,
            size: u32,

            pub fn toLong(inode: FileInode) LFileInode {
                return .{
                    .base = inode.base,
                    .start_block = inode.start_block,
                    .size = inode.size,
                    .sparse = 0,
                    .nlink = 1,
                    .frag_idx = inode.frag_idx,
                    .frag_off = inode.frag_off,
                    .xattr = SquashFs.invalid_xattr,
                };
            }
        };

        pub const SymLinkInode = extern struct {
            base: InodeBase,
            nlink: u32,
            size: u32,
        };

        pub const DevInode = extern struct {
            base: InodeBase,
            nlink: u32,
            rdev: u32,

            pub fn toLong(inode: DevInode) LDevInode {
                return .{
                    .base = inode.base,
                    .nlink = 1,
                    .xattr = SquashFs.invalid_xattr,
                    .rdev = inode.rdev,
                };
            }

            fn major(inode: DevInode) u12 {
                return @intCast((inode.rdev >> 8) & 0xfff);
            }

            fn minor(inode: DevInode) u12 {
                _ = inode;

                //                inode.xtra = .{ .dev = .{
                //                    .major = @intCast((x.rdev >> 8) & 0xfff),
                //                    .minor = @intCast((x.rdev & 0xff) | (x.rdev >> 12) & 0xfff00),
                //                } };
            }
        };

        pub const IpcInode = extern struct {
            base: InodeBase,
            nlink: u32,
        };

        pub const LDirInode = extern struct {
            base: InodeBase,
            nlink: u32,
            size: u32,
            start_block: u32,
            parent_inode: u32,
            i_count: u16,
            offset: u16,
            xattr: u32,
        };

        pub const LFileInode = extern struct {
            base: InodeBase,
            start_block: u64,
            size: u64,
            sparse: u64,
            nlink: u32,
            frag_idx: u32,
            frag_off: u32,
            xattr: u32,
        };

        pub const LDevInode = extern struct {
            base: InodeBase,
            nlink: u32,
            rdev: u32,
            xattr: u32,

            fn major(inode: LDevInode) u12 {
                return @intCast((inode.rdev >> 8) & 0xfff);
            }

            fn minor(inode: LDevInode) u20 {
                return @intCast((inode.rdev & 0xff) | (inode.rdev >> 12) & 0xfff00);
            }
        };

        pub const LIpcInode = extern struct {
            base: InodeBase,
            nlink: u32,
            xattr: u32,
        };
    };

    pub const FragmentEntry = extern struct {
        start_block: u64,
        size: u32,
        unused: u32,
    };

    pub const Options = struct {
        offset: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, opts: Options) !SquashFs {
        var sqfs = SquashFs{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .arena2 = std.heap.ArenaAllocator.init(allocator),
            .version = undefined,
            .file = try fs.cwd().openFile(path, .{}),
            .decompressFn = undefined,
            .super_block = undefined,
            .id_table = undefined,
            .frag_table = undefined,
            .export_table = undefined,
            .xattr_table = undefined,
            .xattr_info = undefined,
            .md_cache = undefined,
            .data_cache = undefined,
            .frag_cache = undefined,
            .blockidx = undefined,
            .offset = opts.offset,
        };

        sqfs.md_cache = try Cache.BlockCacheEntry.init(sqfs.arena.allocator(), SquashFs.cached_blocks);
        sqfs.data_cache = try Cache.BlockCacheEntry.init(sqfs.arena.allocator(), SquashFs.data_cached_blocks);
        sqfs.frag_cache = try Cache.BlockCacheEntry.init(sqfs.arena.allocator(), SquashFs.frag_cached_blocks);
        sqfs.blockidx = try Cache.BlockIdx.init(sqfs.arena.allocator());

        const sb_buf: [*]u8 = @ptrCast(&sqfs.super_block);
        if (try posix.pread(sqfs.file.handle, sb_buf[0..@sizeOf(SuperBlock)], opts.offset) != @sizeOf(SuperBlock)) {
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
            &sqfs,
            @intCast(sqfs.super_block.id_table_start + opts.offset),
            4,
            sqfs.super_block.id_count,
        );

        sqfs.frag_table = try Table.init(
            allocator,
            &sqfs,
            @intCast(sqfs.super_block.fragment_table_start + opts.offset),
            @sizeOf(SquashFs.FragmentEntry),
            sqfs.super_block.fragment_entry_count,
        );

        if (sqfs.super_block.export_table_start != SquashFs.invalid_block) {
            sqfs.export_table = try Table.init(
                allocator,
                &sqfs,
                @intCast(sqfs.super_block.export_table_start + opts.offset),
                8,
                sqfs.super_block.inode_count,
            );
        }

        // TODO: XAttr support
        //try sqfs.XattrInit();

        sqfs.decompressFn = try algos.getDecompressor(
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
        sqfs.id_table.deinit();
        sqfs.frag_table.deinit();

        if (sqfs.export_table) |*export_table| {
            export_table.deinit();
        }

        // Deinit caches
        sqfs.arena.deinit();

        sqfs.arena2.deinit();

        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: u64) !Inode {
        const allocator = sqfs.arena2.allocator();

        // TODO implement block dispose, fix memory leak
        const sqfs_inode = try getInodeFromId(
            allocator,
            sqfs,
            id,
        );

        return Inode{
            .internal = sqfs_inode,
            .parent = sqfs,
            .kind = File.InternalKind.fromInt(
                sqfs_inode.base.kind,
            ).toKind(),
        };
    }

    fn TypeFromFileKind(comptime kind: SquashFs.File.InternalKind) type {
        // zig fmt: off
        return switch (kind) {
            .directory => SquashFs.SuperBlock.DirInode,
            .file      => SquashFs.SuperBlock.FileInode,
            .sym_link, .l_sym_link           => SquashFs.SuperBlock.SymLinkInode,
            .block_device, .character_device => SquashFs.SuperBlock.DevInode,
            .named_pipe, .unix_domain_socket => SquashFs.SuperBlock.IpcInode,

            .l_directory => SquashFs.SuperBlock.LDirInode,
            .l_file      => SquashFs.SuperBlock.LFileInode,
            .l_block_device, .l_character_device => SquashFs.SuperBlock.LDevInode,
            .l_named_pipe, .l_unix_domain_socket => SquashFs.SuperBlock.LIpcInode,
        };
        // zig fmt: on
    }

    fn inodeType(
        comptime kind: SquashFs.File.InternalKind,
        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        inode: *Inode.Internal,
    ) !TypeFromFileKind(kind) {
        const T = TypeFromFileKind(kind);

        var x: T = undefined;

        try sqfs.mdRead(
            allocator,
            &inode.next,
            @as([*]u8, @ptrCast(&x))[0..@sizeOf(T)],
        );

        return littleToNative(x);
    }

    fn getInodeFromId(
        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        id: u64,
    ) !Inode.Internal {
        var inode = Inode.Internal{
            .base = std.mem.zeroes(SquashFs.SuperBlock.InodeBase),
            .nlink = 0,
            .xattr = 0,
            .next = std.mem.zeroes(SquashFs.MdCursor),
            .xtra = undefined,
        };

        inode.xattr = SquashFs.invalid_xattr;

        var cur = SquashFs.MdCursor.fromInodeId(
            id,
            sqfs.super_block.inode_table_start,
        );

        inode.next = cur;

        try sqfs.mdRead(
            allocator,
            //sqfs.arena.allocator(),
            &cur,
            @as([*]u8, @ptrCast(&inode.base))[0..@sizeOf(@TypeOf(inode.base))],
        );

        inode.base = littleToNative(inode.base);
        const kind = File.InternalKind.fromInt(inode.base.kind);

        // zig fmt: off
        inode.base.mode |= switch (kind) {
            .file, .l_file             => posix.S.IFREG,
            .directory, .l_directory   => posix.S.IFDIR,
            .sym_link, .l_sym_link     => posix.S.IFLNK,
            .named_pipe, .l_named_pipe => posix.S.IFIFO,
            .block_device, .l_block_device             => posix.S.IFBLK,
            .character_device, .l_character_device     => posix.S.IFCHR,
            .unix_domain_socket, .l_unix_domain_socket => posix.S.IFSOCK,
        };
        // zig fmt: on

        switch (kind) {
            .file => {
                const x = try inodeType(
                    .file,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .reg = x.toLong() };
            },
            .l_file => {
                const x = try inodeType(
                    .l_file,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .reg = x };
            },
            .directory => {
                const x = try inodeType(
                    .directory,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .dir = x.toLong() };
            },
            .l_directory => {
                const x = try inodeType(
                    .l_directory,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .dir = x };
            },
            .sym_link, .l_sym_link => {
                const x = try inodeType(
                    .sym_link,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .symlink = x };

                if (kind == .l_sym_link) {
                    cur = inode.next;

                    // Skip symlink target
                    try sqfs.mdSkip(
                        sqfs.arena.allocator(),
                        &cur,
                        x.size,
                    );

                    //                    try sqfs.mdRead(
                    //                        sqfs.arena.allocator(),
                    //                        &cur,
                    //                        @as([*]u8, @ptrCast(&inode.xtra.symlink.xattr))[0..4],
                    //                    );
                    //
                    //                    inode.xtra.symlink.xattr = std.mem.littleToNative(
                    //                        u32,
                    //                        inode.xtra.symlink.xattr,
                    //                    );
                }
            },
            .block_device, .character_device => {
                const x = try inodeType(
                    .block_device,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .dev = x.toLong() };
            },
            .l_block_device, .l_character_device => {
                const x = try inodeType(
                    .l_block_device,
                    allocator,
                    sqfs,
                    &inode,
                );

                inode.xtra = .{ .dev = x };
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
            sqfs.super_block.root_inode_id,
        ) catch unreachable;
    }

    fn fragEntry(sqfs: *SquashFs, frag: *FragmentEntry, idx: u32) !void {
        if (idx == SquashFs.invalid_frag) return error.Error;

        try sqfs.frag_table.get(
            sqfs.arena2.allocator(),
            sqfs,
            idx,
            @ptrCast(frag),
        );
    }

    fn dataCache(sqfs: *SquashFs, cache: *Cache, pos: usize, hdr: u32) !*Cache.Block {
        const allocator = sqfs.arena2.allocator();

        var entry = Cache.getCache(
            allocator,
            cache,
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
        pos: *u64,
    ) !*Cache.Block {
        var entry = Cache.getCache(
            allocator,
            sqfs.md_cache,
            pos.*,
        );

        if (!entry.isValid()) {
            entry.data_size = try mdBlockRead(
                allocator,
                sqfs,
                pos.*,
                &entry.block,
            );

            entry.markValid();
        }

        pos.* += @intCast(entry.data_size);

        return entry.block;
    }

    pub const Inode = struct {
        internal: Inode.Internal,
        parent: *SquashFs,
        kind: File.Kind,
        pos: u64 = 0,

        // TODO: move this into parent inode
        const Internal = extern struct {
            base: SquashFs.SuperBlock.InodeBase,
            nlink: u32,
            xattr: u32,
            next: SquashFs.MdCursor,

            xtra: extern union {
                reg: SuperBlock.LFileInode,
                dev: SuperBlock.LDevInode,
                symlink: SuperBlock.SymLinkInode,
                dir: SuperBlock.LDirInode,
            },
        };

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
                sqfs.frag_cache,
                @intCast(frag.start_block),
                frag.size,
            );

            offset.* = inode.internal.xtra.reg.frag_off;
            size.* = @intCast(inode.internal.xtra.reg.size % sqfs.super_block.block_size);

            return block;
        }

        /// Reads the link target into `buf`
        pub fn readLink(inode: *Inode, buf: []u8) ![]const u8 {
            if (inode.kind != .sym_link) {
                // TODO: rename
                return error.NotLink;
            }

            const len = inode.internal.xtra.symlink.size;

            if (len > buf.len - 1) {
                return error.NoSpaceLeft;
            }

            var cur = inode.internal.next;

            try inode.parent.mdRead(
                inode.parent.arena.allocator(),
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

        // TODO: Move these to `SquashFs.File`
        pub const ReadError = std.fs.File.ReadError;
        pub fn read(self: *Inode, buf: []u8) ReadError!usize {
            const buf_len = try self.pread(
                buf,
                @truncate(self.pos),
            );

            self.pos += buf_len;

            return @truncate(buf_len);
        }

        pub const PReadError = ReadError;
        pub fn pread(
            inode: *SquashFs.Inode,
            buf: []u8,
            offset: usize,
        ) PReadError!usize {
            if (inode.kind == .directory) return error.IsDir;

            var nbuf = buf;
            var sqfs = inode.parent;

            const file_size = inode.internal.xtra.reg.size;
            const block_size = sqfs.super_block.block_size;

            if (nbuf.len < 0 or offset > file_size) return error.InputOutput;

            if (offset == file_size) {
                nbuf.len = 0;
                return 0;
            }

            var bl: SquashFs.File.BlockList = undefined;
            Cache.BlockIdx.blockList(
                sqfs,
                inode,
                &bl,
                offset,
            ) catch return error.SystemResources;

            var read_off = offset % block_size;

            while (nbuf.len > 0) {
                var block: ?*Cache.Block = null;
                var data_off: usize = 0;
                var data_size: usize = 0;
                var take: usize = 0;

                const fragment = bl.remain == 0;
                if (fragment) {
                    if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) break;

                    block = inode.fragBlock(
                        &data_off,
                        &data_size,
                    ) catch return error.SystemResources;
                } else {
                    // TODO
                    bl.next(sqfs.allocator) catch return error.SystemResources;

                    if (bl.pos + block_size <= offset) continue;

                    data_off = 0;
                    if (bl.input_size == 0) {
                        data_size = @intCast(file_size - bl.pos);

                        if (data_size > block_size) data_size = block_size;
                    } else {
                        block = sqfs.dataCache(
                            @ptrCast(@alignCast(sqfs.data_cache)),
                            @intCast(bl.block),
                            bl.header,
                        ) catch return error.SystemResources;

                        data_size = block.?.data.len;
                    }
                }

                take = data_size - read_off;
                if (take > nbuf.len) take = nbuf.len;

                if (block != null) {
                    @memcpy(nbuf[0..take], block.?.data[data_off + read_off ..][0..take]);
                } else {
                    @memset(nbuf[0..take], 0);
                }

                read_off = 0;
                nbuf = nbuf[take..];

                if (fragment) break;
            }

            const size = buf.len - nbuf.len;

            if (size == 0) return error.InputOutput;

            return size;
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

        pub const GetSeekPosError = posix.SeekError || posix.FStatError;
        pub const SeekError = posix.SeekError || error{InvalidSeek};

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
            return @intCast(self.internal.xtra.reg.size);
        }

        pub const Reader = io.Reader(Inode, os.ReadError, read);

        pub fn reader(self: *Inode) Reader {
            return .{ .context = self };
        }

        fn getId(allocator: std.mem.Allocator, sqfs: *SquashFs, idx: u16) !u32 {
            var id: [4]u8 = undefined;

            try sqfs.id_table.get(
                allocator,
                sqfs,
                idx,
                &id,
            );

            return std.mem.littleToNative(
                u32,
                @bitCast(id),
            );
        }

        pub fn stat(inode: *Inode) !fs.File.Stat {
            const mtime = @as(i128, inode.internal.base.mtime) * std.time.ns_per_s;

            return .{
                // TODO
                .inode = 0,
                .size = switch (inode.kind) {
                    .file => inode.internal.xtra.reg.size,
                    .sym_link => inode.internal.xtra.symlink.size,
                    .directory => inode.internal.xtra.dir.size,
                    else => 0,
                },

                // Only exists on posix platforms
                .mode = if (fs.File.Mode == u0) 0 else inode.internal.base.mode,

                .kind = switch (inode.kind) {
                    .block_device => .block_device,
                    .character_device => .character_device,
                    .directory => .directory,
                    .named_pipe => .named_pipe,
                    .sym_link => .sym_link,
                    .file => .file,
                    .unix_domain_socket => .unix_domain_socket,
                },

                .atime = mtime,
                .ctime = mtime,
                .mtime = mtime,
            };
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
        pub fn statC(inode: *Inode) !posix.Stat {
            var st = std.mem.zeroes(posix.Stat);

            st.mode = inode.internal.base.mode;
            st.nlink = @intCast(inode.internal.nlink);

            st.atim.tv_sec = @intCast(inode.internal.base.mtime);
            st.ctim.tv_sec = @intCast(inode.internal.base.mtime);
            st.mtim.tv_sec = @intCast(inode.internal.base.mtime);

            switch (inode.kind) {
                .file => {
                    st.size = @intCast(inode.internal.xtra.reg.size);
                    st.blocks = @divTrunc(st.size, 512);
                },
                .block_device, .character_device => {
                    st.rdev = inode.internal.xtra.dev.rdev;
                    //                    st.rdev = makeDev(
                    //                        @intCast(inode.internal.xtra.dev.major()),
                    //                        @intCast(inode.internal.xtra.dev.minor()),
                    //                    );
                },
                .sym_link => {
                    st.size = @intCast(inode.internal.xtra.symlink.size);
                },
                else => {},
            }

            st.blksize = @intCast(inode.parent.super_block.block_size);

            st.uid = try getId(inode.parent.arena.allocator(), inode.parent, inode.internal.base.uid);
            st.gid = try getId(inode.parent.arena.allocator(), inode.parent, inode.internal.base.guid);

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
                id: u64,
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
                //var sqfs_dir_entry: Dir.Entry = undefined;

                //               sqfs_dir_entry.name = &self.name_buf;

                var iterator = Dir.Iterator{
                    .name_buf = &self.name_buf,
                    .sqfs = self.parent,
                    .allocator = self.dir.parent.arena.allocator(),
                    .dir = &self.internal,
                };

                const sqfs_dir_entry = try iterator.next() orelse return null;

                //                if (!found) return null;

                // Append null byte
                self.name_buf[sqfs_dir_entry.name.len] = '\x00';

                return .{
                    .id = sqfs_dir_entry.inode,
                    .name = self.name_buf[0..sqfs_dir_entry.name.len :0],
                    .kind = sqfs_dir_entry.kind,
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
                id: u64,
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
                    const fsize: u64 = self.internal.xtra.reg.size;

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
                    var link_target_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

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

            pub fn fromInt(int: u16) InternalKind {
                return @enumFromInt(int);
            }

            pub fn toKind(kind: InternalKind) Kind {
                const kind_int = @intFromEnum(kind);

                return if (kind_int <= 7) blk: {
                    break :blk @enumFromInt(kind_int);
                } else blk: {
                    break :blk @enumFromInt(kind_int - 7);
                };
            }
        };

        pub const BlockList = extern struct {
            sqfs: *SquashFs,
            remain: usize,
            cur: MdCursor,
            started: bool,

            pos: u64,

            block: u64,
            header: u32,
            input_size: u32,

            pub fn init(sqfs: *SquashFs, inode: *Inode) !BlockList {
                return .{
                    .sqfs = sqfs,
                    .remain = BlockList.count(sqfs, inode),
                    .cur = inode.internal.next,
                    .started = false,
                    .pos = 0,
                    .header = 0,
                    .block = inode.internal.xtra.reg.start_block,
                    .input_size = 0,
                };
            }

            pub fn count(sqfs: *SquashFs, inode: *Inode) usize {
                const size = inode.internal.xtra.reg.size;
                const block = sqfs.super_block.block_size;

                if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) {
                    return @intCast(std.math.divCeil(u64, size, block) catch unreachable);
                }

                return @intCast(size / block);
            }

            pub fn next(bl: *BlockList, allocator: std.mem.Allocator) !void {
                if (bl.remain == 0) {
                    // TODO: better errors
                    return error.NoRemain;
                }

                bl.remain -= 1;

                try bl.sqfs.mdRead(
                    allocator,
                    &bl.cur,
                    @as([*]u8, @ptrCast(&bl.header))[0..4],
                );

                bl.header = littleToNative(bl.header);

                bl.block += bl.input_size;

                // sqfs_data_header
                bl.input_size = bl.header & ~@as(u32, SquashFs.compressed_bit_block);

                if (bl.started) {
                    bl.pos += bl.sqfs.super_block.block_size;
                }

                bl.started = true;
            }
        };
    };

    pub const Dir = @import("Dir.zig");

    pub const MdCursor = extern struct {
        block: u64,
        offset: usize,

        pub fn fromInodeId(id: u64, base: u64) MdCursor {
            return .{
                .block = @intCast((id >> 16) + base),
                .offset = @intCast(id & 0xffff),
            };
        }
    };

    pub fn mdRead(
        sqfs: *SquashFs,
        allocator: std.mem.Allocator,
        cur: *SquashFs.MdCursor,
        buf: []u8,
    ) !void {
        var pos = cur.block;

        var size = buf.len;
        var nbuf = buf;

        while (size > 0) {
            const block = try sqfs.mdCache(allocator, &pos);

            var take = block.data.len - cur.offset;
            if (take > size) {
                take = size;
            }

            @memcpy(
                nbuf[0..take],
                block.data[cur.offset..][0..take],
            );

            nbuf = nbuf[take..];

            size -= take;
            cur.offset += take;

            if (cur.offset == block.data.len) {
                cur.block = pos;
                cur.offset = 0;
            }
        }
    }

    pub fn mdSkip(
        sqfs: *SquashFs,
        allocator: std.mem.Allocator,
        cur: *SquashFs.MdCursor,
        skip: usize,
    ) !void {
        var pos = cur.block;

        var size = skip;

        while (size > 0) {
            const block = try sqfs.mdCache(allocator, &pos);

            var take = block.data.len - cur.offset;
            if (take > size) {
                take = size;
            }

            size -= take;
            cur.offset += take;

            if (cur.offset == block.data.len) {
                cur.block = pos;
                cur.offset = 0;
            }
        }
    }

    pub const XattrId = packed struct {
        xattr: u64,
        count: u32,
        size: u32,
    };

    pub const XattrIdTable = packed struct {
        table_start: u64,
        ids: u32,
        UNUSED: u32,
    };

    pub fn XattrInit(sqfs: *SquashFs) !void {
        var start = sqfs.super_block.xattr_id_table_start;
        _ = &start;

        if (start == SquashFs.invalid_block) return;

        const xattr_u8: [*]u8 = @ptrCast(&sqfs.xattr_info);
        const xattr_size = @sizeOf(@TypeOf(sqfs.xattr_info));
        if (try posix.pread(
            sqfs.file.handle,
            xattr_u8[0..xattr_size],
            start + sqfs.offset,
        ) != xattr_size) {
            return error.ReadFailed;
        }

        sqfs.xattr_info = littleToNative(sqfs.xattr_info);

        sqfs.xattr_table = @bitCast(try Table.init(
            sqfs.allocator,
            sqfs.file.handle,
            @intCast(start + xattr_size + sqfs.offset),
            @sizeOf(XattrId),
            sqfs.xattr_info.xattr_ids,
        ));
    }

    // TODO: type safety
    /// Load data directly from image into a structure
    pub fn load(sqfs: *SquashFs, slice: anytype, offset: u64) !void {
        const T = @TypeOf(slice);

        switch (@typeInfo(T)) {
            .Pointer => |info| {
                //const size = @sizeOf(@typeInfo(ChildT).Pointer.child);
                const size = if (info.size == .Slice) blk: {
                    const ChildT = @TypeOf(slice.ptr);
                    break :blk @sizeOf(@typeInfo(ChildT).Pointer.child) * slice.len;
                } else blk: {
                    break :blk @sizeOf(@typeInfo(T).Pointer.child);
                };

                const item_u8: [*]u8 = if (info.size == .Slice) blk: {
                    break :blk @ptrCast(slice.ptr);
                } else blk: {
                    break :blk @ptrCast(slice);
                };

                if (try posix.pread(
                    sqfs.file.handle,
                    item_u8[0..size],
                    offset,
                ) != size) {
                    return error.PartialRead;
                }
            },
            else => unreachable,
        }
    }

    //    pub fn fragEntry(sqfs: *SquashFs, )
};

fn dataBlockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: usize,
    hdr_le: u32,
) !*Cache.Block {
    const size = hdr_le & ~@as(u32, SquashFs.compressed_bit_block);
    const compressed = hdr_le & SquashFs.compressed_bit_block == 0;

    return blockRead(
        allocator,
        sqfs,
        pos,
        compressed,
        size,
        sqfs.super_block.block_size,
    );
}

fn blockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: u64,
    compressed: bool,
    size: u32,
    out_size: usize,
) !*Cache.Block {
    var block = try allocator.create(Cache.Block);

    block.refcount = 1;

    block.data = try allocator.alloc(u8, size);

    //    var written = out_size;

    try sqfs.load(
        block.data,
        pos + sqfs.offset,
    );

    if (compressed) {
        const decomp = try allocator.alloc(u8, out_size);

        const written = sqfs.decompressFn(
            allocator,
            block.data,
            decomp[0..out_size],
        ) catch blk: {
            allocator.free(decomp);
            break :blk 0;
        };

        //std.debug.print("{d} {d} {d} {}\n", .{ size, out_size, written, compressed });

        allocator.free(block.data);

        const ret = allocator.resize(decomp, written);
        block.data = decomp[0..written];
        _ = ret;

        //std.debug.print("{d} {}\n", .{ block.data.len, ret });
        //std.debug.print("{d} {}\n", .{ decomp.len, ret });
    }

    return block;
}

pub fn mdBlockRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: u64,
    block: **Cache.Block,
) !usize {
    var hdr: [2]u8 = undefined;

    try sqfs.load(
        &hdr,
        pos + sqfs.offset,
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
