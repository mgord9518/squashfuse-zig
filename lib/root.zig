const std = @import("std");
const io = std.io;
const os = std.os;
const posix = std.posix;
const fs = std.fs;

// TODO: is this always correct?
const S = std.os.linux.S;

const Stat = std.os.linux.Stat;

pub const build_options = @import("build_options");

const Cache = @import("Cache.zig").Cache;
const BlockIdx = @import("Cache.zig").BlockIdx;
const Table = @import("table.zig").Table;

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

    id_table: Table(u32),
    frag_table: Table(Block.FragmentEntry),
    export_table: ?Table(u64),
    xattr_table: Table(XattrId),

    //blockidx: *Cache(BlockCacheEntry),
    blockidx: Cache(*BlockIdx.Entry),

    md_cache: Cache(Block),
    data_cache: Cache(Block),
    frag_cache: Cache(Block),

    xattr_info: XattrIdTable,
    //compression_options: Compression.Options,

    offset: u64,

    pub const SuperBlock = @import("super_block.zig").SuperBlock;
    pub const Block = @import("Block.zig");

    pub const magic: [4]u8 = "hsqs".*;

    pub const metadata_size = 1024 * 8;

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

        // TODO: load this value
        pub const Options = union(Compression) {
            zlib: extern struct {
                compression_level: u32,
                window_size: u16,
                strategies: Strategies,

                pub const Strategies = packed struct(u16) {
                    default: bool,
                    filtered: bool,
                    huffman_only: bool,
                    run_length_encoded: bool,
                    fixed: bool,
                    UNUSED: u11 = undefined,
                };
            },
            lzma: u0,
            lzo: extern struct {
                algorithm: Algorithm,
                compression_level: u32,

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
                    UNUSED: u26 = undefined,
                };
            },
            lz4: extern struct {
                version: u32,
                flags: Flags,

                pub const Flags = packed struct(u32) {
                    lz4_hc: bool,
                    UNUSED: u31 = undefined,
                };
            },
            zstd: extern struct {
                compression_level: u32,
            },
        };
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

        sqfs.md_cache = try Cache(
            Block,
        ).init(
            sqfs.allocator,
            SquashFs.cached_blocks,
        );

        sqfs.data_cache = try Cache(
            Block,
        ).init(
            sqfs.allocator,
            SquashFs.data_cached_blocks,
        );

        sqfs.frag_cache = try Cache(
            Block,
        ).init(
            sqfs.allocator,
            SquashFs.frag_cached_blocks,
        );

        sqfs.blockidx = try Cache(
            *BlockIdx.Entry,
        ).init(
            sqfs.allocator,
            SquashFs.frag_cached_blocks,
        );

        try sqfs.load(&sqfs.super_block, opts.offset);

        sqfs.super_block.inode_count = littleToNative(sqfs.super_block.inode_count);
        sqfs.super_block.modification_time = littleToNative(sqfs.super_block.modification_time);
        sqfs.super_block.block_size = littleToNative(sqfs.super_block.block_size);
        sqfs.super_block.fragment_entry_count = littleToNative(sqfs.super_block.fragment_entry_count);
        sqfs.super_block.compression = @enumFromInt(littleToNative(@intFromEnum(sqfs.super_block.compression)));
        sqfs.super_block.block_log = littleToNative(sqfs.super_block.block_log);
        sqfs.super_block.flags = littleToNative(sqfs.super_block.flags);
        sqfs.super_block.id_count = littleToNative(sqfs.super_block.id_count);
        sqfs.super_block.version_major = littleToNative(sqfs.super_block.version_major);
        sqfs.super_block.version_minor = littleToNative(sqfs.super_block.version_minor);
        sqfs.super_block.root_inode_id = littleToNative(sqfs.super_block.root_inode_id);
        sqfs.super_block.bytes_used = littleToNative(sqfs.super_block.bytes_used);
        sqfs.super_block.id_table_start = littleToNative(sqfs.super_block.id_table_start);
        sqfs.super_block.xattr_id_table_start = littleToNative(sqfs.super_block.xattr_id_table_start);
        sqfs.super_block.inode_table_start = littleToNative(sqfs.super_block.inode_table_start);
        sqfs.super_block.directory_table_start = littleToNative(sqfs.super_block.directory_table_start);
        sqfs.super_block.fragment_table_start = littleToNative(sqfs.super_block.fragment_table_start);
        sqfs.super_block.export_table_start = littleToNative(sqfs.super_block.export_table_start);

        sqfs.id_table = try Table(u32).init(
            allocator,
            &sqfs,
            @intCast(sqfs.super_block.id_table_start + opts.offset),
            sqfs.super_block.id_count,
        );

        sqfs.frag_table = try Table(Block.FragmentEntry).init(
            allocator,
            &sqfs,
            @intCast(sqfs.super_block.fragment_table_start + opts.offset),
            sqfs.super_block.fragment_entry_count,
        );

        if (sqfs.super_block.export_table_start != SquashFs.invalid_block) {
            sqfs.export_table = try Table(u64).init(
                allocator,
                &sqfs,
                @intCast(sqfs.super_block.export_table_start + opts.offset),
                sqfs.super_block.inode_count,
            );
        }

        // TODO: XAttr support
        //try sqfs.XattrInit();

        sqfs.decompressFn = try compression.getDecompressor(
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

        // Deinit block caches
        sqfs.md_cache.deinit();
        sqfs.data_cache.deinit();
        sqfs.frag_cache.deinit();

        sqfs.blockidx.deinit();

        sqfs.arena.deinit();

        sqfs.arena2.deinit();

        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: Inode.TableEntry) !Inode {
        const allocator = sqfs.arena2.allocator();
        //const allocator = sqfs.allocator;

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

    fn getInodeFromId(
        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        id: Inode.TableEntry,
    ) !Inode.Internal {
        var inode = Inode.Internal{
            .base = std.mem.zeroes(SquashFs.SuperBlock.InodeBase),
            .nlink = 0,
            .xattr = 0,
            .next = std.mem.zeroes(SquashFs.MetadataCursor),
            .xtra = undefined,
        };

        inode.xattr = SquashFs.invalid_xattr;

        var cur = MetadataCursor{
            .sqfs = sqfs,
            .block = id.block + sqfs.super_block.inode_table_start,
            .offset = id.offset,
        };

        inode.next = cur;

        try cur.load(
            allocator,
            &inode.base,
        );

        inode.base = littleToNative(inode.base);
        const kind = File.InternalKind.fromInt(inode.base.kind);

        // zig fmt: off
        inode.base.mode |= switch (kind) {
            .file, .l_file             => S.IFREG,
            .directory, .l_directory   => S.IFDIR,
            .sym_link, .l_sym_link     => S.IFLNK,
            .named_pipe, .l_named_pipe => S.IFIFO,
            .block_device, .l_block_device             => S.IFBLK,
            .character_device, .l_character_device     => S.IFCHR,
            .unix_domain_socket, .l_unix_domain_socket => S.IFSOCK,
        };
        // zig fmt: on

        switch (kind) {
            .file => {
                var x: SuperBlock.FileInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .reg = x.toLong() };
            },
            .l_file => {
                var x: SuperBlock.LFileInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .reg = x };
            },
            .directory => {
                var x: SuperBlock.DirInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .dir = x.toLong() };
            },
            .l_directory => {
                var x: SuperBlock.LDirInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .dir = x };
            },
            .sym_link, .l_sym_link => {
                var x: SuperBlock.SymLinkInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .symlink = x };

                if (kind == .l_sym_link) {
                    cur = inode.next;

                    // Skip symlink target
                    try sqfs.mdSkip(
                        allocator,
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
                var x: SuperBlock.DevInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .dev = x.toLong() };
            },
            .l_block_device, .l_character_device => {
                var x: SuperBlock.LDevInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .dev = x };
            },
            .unix_domain_socket, .named_pipe => {
                var x: SuperBlock.IpcInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

                inode.nlink = @intCast(x.nlink);
            },
            .l_unix_domain_socket, .l_named_pipe => {
                var x: SuperBlock.LIpcInode = undefined;

                try inode.next.load(
                    allocator,
                    &x,
                );

                x = littleToNative(x);

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

    fn fragEntry(sqfs: *SquashFs, frag: *Block.FragmentEntry, idx: u32) !void {
        if (idx == SquashFs.invalid_frag) return error.Error;

        try sqfs.frag_table.get(
            //sqfs.arena.allocator(),
            sqfs.allocator,
            sqfs,
            idx,
            frag,
        );
    }

    fn dataCache(
        sqfs: *SquashFs,
        cache: *Cache(Block),
        pos: u64,
        header: Block.DataEntry,
    ) !Block {
        //const allocator = sqfs.arena2.allocator();
        const allocator = sqfs.allocator;

        var entry = cache.get(@truncate(pos));

        if (!entry.header.valid) {
            entry.entry = try dataBlockRead(
                allocator,
                sqfs,
                pos,
                header,
            );

            entry.header.valid = true;
        }

        return entry.entry;

        // TODO: sqfs_block_ref
    }

    pub fn mdCache(
        sqfs: *SquashFs,
        allocator: std.mem.Allocator,
        pos: *u64,
    ) !Block {
        var entry = sqfs.md_cache.get(pos.*);

        // Block not yet in cache, add it
        if (!entry.header.valid) {
            var header: Block.MetadataEntry = undefined;

            try sqfs.load(
                &header,
                pos.* + sqfs.offset,
            );

            header = littleToNative(
                header,
            );

            entry.entry = try blockRead(
                allocator,
                sqfs,
                // 2 == @sizeOf(header)
                pos.* + 2,
                !header.is_uncompressed,
                header.size,
                SquashFs.metadata_size,
            );

            entry.entry.data_size = header.size + 2;

            entry.header.valid = true;
        }

        pos.* += entry.entry.data_size;

        return entry.entry;
    }

    pub const Inode = struct {
        internal: Inode.Internal,
        parent: *SquashFs,
        kind: File.Kind,
        pos: u64 = 0,

        pub const TableEntry = packed struct {
            offset: u16,
            block: u32,
            UNUSED: u16 = 0,
        };

        // TODO: move this into parent inode
        const Internal = extern struct {
            base: SquashFs.SuperBlock.InodeBase,
            nlink: u32,
            xattr: u32,
            next: SquashFs.MetadataCursor,

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
        ) !Block {
            var sqfs = inode.parent;
            //var block: *Block = undefined;
            var block: Block = undefined;

            var frag: Block.FragmentEntry = undefined;

            if (inode.kind != .file) return error.Error;

            try sqfs.fragEntry(
                &frag,
                inode.internal.xtra.reg.frag_idx,
            );

            block = try sqfs.dataCache(
                &sqfs.frag_cache,
                frag.start_block,
                frag.block_header,
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

            try cur.read(
                inode.parent.arena.allocator(),
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

            //var bl: SquashFs.File.BlockList = undefined;
            var bl = BlockIdx.blockList(
                sqfs,
                inode,
                //&bl,
                offset,
            ) catch return error.SystemResources;

            var read_off = offset % block_size;

            while (nbuf.len > 0) {
                var block: ?Block = null;
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
                            //@ptrCast(@alignCast(sqfs.data_cache)),
                            &sqfs.data_cache,
                            bl.block,
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
            return self.internal.xtra.reg.size;
        }

        pub const Reader = io.Reader(Inode, os.ReadError, read);

        pub fn reader(self: *Inode) Reader {
            return .{ .context = self };
        }

        fn getId(allocator: std.mem.Allocator, sqfs: *SquashFs, idx: u16) !u32 {
            var id: u32 = undefined;

            try sqfs.id_table.get(
                allocator,
                sqfs,
                idx,
                &id,
            );

            return std.mem.littleToNative(
                u32,
                id,
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
        pub fn statC(inode: *Inode) !Stat {
            var st = std.mem.zeroes(Stat);

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
                    st.rdev = @as(u32, @bitCast(inode.internal.xtra.dev.dev));
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

            st.uid = try getId(inode.parent.allocator, inode.parent, inode.internal.base.uid);
            st.gid = try getId(inode.parent.allocator, inode.parent, inode.internal.base.guid);

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
                id: Inode.TableEntry,
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
                id: Inode.TableEntry,
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
                    if (std.fs.has_executable_bit) {
                        const st = try self.stat();
                        try f.chmod(st.mode);
                    }
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

                .block_device, .character_device => {
                    const dev = self.internal.xtra.dev;

                    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                    const path = try std.fmt.bufPrintZ(&path_buf, "{s}", .{dest});

                    _ = std.os.linux.mknod(path, dev.major(), dev.minor());
                },

                // TODO: implement for other types
                else => {
                    var panic_buf: [256]u8 = undefined;

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
            cur: MetadataCursor,
            started: bool,

            pos: u64,

            block: u64,
            header: Block.DataEntry,
            input_size: u32,

            pub fn init(sqfs: *SquashFs, inode: *Inode) !BlockList {
                return .{
                    .sqfs = sqfs,
                    .remain = BlockList.count(sqfs, inode),
                    .cur = inode.internal.next,
                    .started = false,
                    .pos = 0,
                    .header = .{ .is_uncompressed = false, .size = 0 },
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

                try bl.cur.load(
                    allocator,
                    &bl.header,
                );

                bl.header = littleToNative(bl.header);

                bl.block += bl.input_size;

                bl.input_size = bl.header.size;

                if (bl.started) {
                    bl.pos += bl.sqfs.super_block.block_size;
                }

                bl.started = true;
            }
        };
    };

    pub const Dir = @import("fs/Dir.zig");

    pub const MetadataCursor = extern struct {
        sqfs: *SquashFs,
        block: u64,
        offset: usize,

        /// Reads
        pub fn load(
            cur: *SquashFs.MetadataCursor,
            allocator: std.mem.Allocator,
            pointer: anytype,
        ) !void {
            const T = @TypeOf(pointer);

            switch (@typeInfo(T)) {
                .Pointer => |info| {
                    const size = if (info.size == .Slice) blk: {
                        const ChildT = @TypeOf(pointer.ptr);
                        break :blk @sizeOf(@typeInfo(ChildT).Pointer.child) * pointer.len;
                    } else blk: {
                        break :blk @sizeOf(@typeInfo(T).Pointer.child);
                    };

                    const item_u8: [*]u8 = if (info.size == .Slice) blk: {
                        break :blk @ptrCast(pointer.ptr);
                    } else blk: {
                        break :blk @ptrCast(pointer);
                    };

                    try cur.read(allocator, item_u8[0..size]);
                },
                else => unreachable,
            }
        }

        pub fn read(
            cur: *SquashFs.MetadataCursor,
            allocator: std.mem.Allocator,
            buf: []u8,
        ) !void {
            var pos = cur.block;

            var size = buf.len;
            var nbuf = buf;

            while (size > 0) {
                const block = try cur.sqfs.mdCache(allocator, &pos);

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
    };

    pub fn mdSkip(
        sqfs: *SquashFs,
        allocator: std.mem.Allocator,
        cur: *SquashFs.MetadataCursor,
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

        sqfs.xattr_table = @bitCast(try Table(XattrId).init(
            sqfs.allocator,
            sqfs.file.handle,
            @intCast(start + xattr_size + sqfs.offset),
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
    pos: u64,
    header: SquashFs.Block.DataEntry,
) !SquashFs.Block {
    return blockRead(
        allocator,
        sqfs,
        pos,
        !header.is_uncompressed,
        header.size,
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
) !SquashFs.Block {
    var block = SquashFs.Block{
        .refcount = 1,
        .data = try allocator.alloc(u8, size),
        .allocator = allocator,
    };

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

        allocator.free(block.data);

        block.data = decomp[0..written];
        const ret = allocator.resize(block.data, written);
        _ = ret;
    }

    return block;
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
pub const compression = @import("compression.zig");

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
