const std = @import("std");
const posix = std.posix;
const fs = std.fs;

const metadata = @import("metadata.zig");

// TODO: is this always correct?
const S = std.os.linux.S;

const Stat = std.os.linux.Stat;

pub const compression = @import("compression.zig");
pub const build_options = @import("build_options");

const Cache = @import("cache.zig").Cache;
const Table = @import("table.zig").Table;

pub const SquashFsError = error{
    Error,
    InvalidFormat,
    InvalidVersion,
    InvalidCompression,
    UnsupportedFeature,
    NotRegularFile,
};

/// Top-level SquashFS object; should fully implement std.fs.Dir functionality
pub const SquashFs = struct {
    allocator: std.mem.Allocator,
    file: fs.File,
    decompressFn: compression.Decompressor,
    super_block: SuperBlock,

    id_table: Table(u32),
    frag_table: Table(Block.FragmentEntry),
    export_table: ?Table(u64),
    xattr_table: Table(XattrId),

    md_cache: Cache(metadata.Block),
    data_cache: Cache([]u8),
    frag_cache: Cache([]u8),

    inode_map: ?std.StringHashMap(Inode.TableEntry) = null,

    xattr_info: XattrIdTable,
    //compression_options: Compression.Options,

    opts: SquashFs.Options,

    pub const SuperBlock = @import("super_block.zig").SuperBlock;
    pub const Block = @import("Block.zig");

    pub const magic = "hsqs";

    pub const metadata_block_size = 1024 * 8;

    pub const invalid_xattr = 0xffff_ffff;
    pub const invalid_frag = 0xffff_ffff;
    pub const invalid_block = 0xffff_ffff_ffff_ffff;

    pub const supported_version = std.SemanticVersion{
        .major = 4,
        .minor = 0,
        .patch = 0,
    };

    pub const Options = struct {
        offset: u64 = 0,

        cached_metadata_blocks: usize = 8,
        cached_data_blocks: usize = 8,
        cached_fragment_blocks: usize = 3,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        opts: Options,
    ) !*SquashFs {
        const sqfs = try allocator.create(SquashFs);

        // TODO: why does it crash (incorrect alignment) without this?
        if (true) {
            sqfs.* = SquashFs{
                .opts = undefined,
                .allocator = undefined,
                .file = undefined,
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
            };
        }

        sqfs.opts = opts;
        sqfs.allocator = allocator;
        sqfs.file = try fs.cwd().openFile(path, .{});

        try sqfs.load(&sqfs.super_block, opts.offset);

        if (!std.mem.eql(u8, &sqfs.super_block.magic, SquashFs.magic)) {
            return SquashFsError.InvalidFormat;
        }

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

        const flags = sqfs.super_block.flags;

        if (flags.uncompressed_inodes and
            flags.uncompressed_data and
            flags.uncompressed_fragments)
        {
            sqfs.super_block.compression = .none;
        }

        sqfs.md_cache = try Cache(
            metadata.Block,
        ).init(
            sqfs.allocator,
            sqfs.opts.cached_metadata_blocks,
            .{ .block_size = SquashFs.metadata_block_size },
        );

        sqfs.data_cache = try Cache(
            []u8,
        ).init(
            sqfs.allocator,
            sqfs.opts.cached_data_blocks,
            .{ .block_size = sqfs.super_block.block_size },
        );

        sqfs.frag_cache = try Cache(
            []u8,
        ).init(
            sqfs.allocator,
            sqfs.opts.cached_fragment_blocks,
            .{ .block_size = sqfs.super_block.block_size },
        );

        sqfs.id_table = try Table(u32).init(
            allocator,
            sqfs,
            sqfs.super_block.id_table_start + opts.offset,
            sqfs.super_block.id_count,
        );

        sqfs.frag_table = try Table(Block.FragmentEntry).init(
            allocator,
            sqfs,
            sqfs.super_block.fragment_table_start + opts.offset,
            sqfs.super_block.fragment_entry_count,
        );

        if (sqfs.super_block.export_table_start != SquashFs.invalid_block) {
            sqfs.export_table = try Table(u64).init(
                allocator,
                sqfs,
                sqfs.super_block.export_table_start + opts.offset,
                sqfs.super_block.inode_count,
            );
        }

        // TODO: XAttr support
        //try sqfs.XattrInit();

        sqfs.decompressFn = try compression.getDecompressor(
            sqfs.super_block.compression,
        );

        return sqfs;
    }

    pub fn deinit(sqfs: *SquashFs) void {
        sqfs.id_table.deinit();
        sqfs.frag_table.deinit();

        if (sqfs.export_table) |*export_table| {
            export_table.deinit();
        }

        if (sqfs.inode_map) |*inode_map| {
            var it = inode_map.keyIterator();

            while (it.next()) |key| {
                sqfs.allocator.free(key.*);
            }

            inode_map.deinit();
        }

        sqfs.md_cache.deinit();
        sqfs.data_cache.deinit();
        sqfs.frag_cache.deinit();

        sqfs.file.close();

        sqfs.allocator.destroy(sqfs);
    }

    pub fn version(sqfs: *const SquashFs) std.SemanticVersion {
        return .{
            .major = sqfs.super_block.version_major,
            .minor = sqfs.super_block.version_minor,
            .patch = 0,
        };
    }

    pub inline fn getInode(sqfs: *SquashFs, id: Inode.TableEntry) !Inode {
        const sqfs_inode = try getInodeFromId(
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
        sqfs: *SquashFs,
        id: Inode.TableEntry,
    ) !Inode.Internal {
        var inode = Inode.Internal{
            .base = std.mem.zeroes(SquashFs.SuperBlock.InodeBase),
            .nlink = 0,
            .xattr = 0,
            .next = std.mem.zeroes(metadata.Cursor),
            .xtra = undefined,
        };

        inode.xattr = SquashFs.invalid_xattr;

        var cur = metadata.Cursor{
            .sqfs = sqfs,
            .block = id.block + sqfs.super_block.inode_table_start,
            .offset = id.offset,
        };

        inode.next = cur;

        try cur.load(
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

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .reg = x.toLong() };
            },
            .l_file => {
                var x: SuperBlock.LFileInode = undefined;

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .reg = x };
            },
            .directory => {
                var x: SuperBlock.DirInode = undefined;

                try inode.next.load(
                    &x,
                );

                x = littleToNative(x);

                inode.xtra = .{ .dir = x.toLong() };
            },
            .l_directory => {
                var x: SuperBlock.LDirInode = undefined;

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .dir = x };
            },
            .sym_link, .l_sym_link => {
                var x: SuperBlock.SymLinkInode = undefined;

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .symlink = x };

                if (kind == .l_sym_link) {
                    cur = inode.next;

                    // Skip symlink target
                    try sqfs.mdSkip(
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

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .dev = x.toLong() };
            },
            .l_block_device, .l_character_device => {
                var x: SuperBlock.LDevInode = undefined;

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.xtra = .{ .dev = x };
            },
            .unix_domain_socket, .named_pipe => {
                var x: SuperBlock.IpcInode = undefined;

                try inode.next.load(&x);

                x = littleToNative(x);

                inode.nlink = @intCast(x.nlink);
            },
            .l_unix_domain_socket, .l_named_pipe => {
                var x: SuperBlock.LIpcInode = undefined;

                try inode.next.load(&x);

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

    pub fn root(sqfs: *SquashFs) Dir {
        const inode = sqfs.getInode(
            sqfs.super_block.root_inode_id,
        ) catch unreachable;

        if (inode.kind != .directory) unreachable;

        return .{
            .sqfs = sqfs,
            .cur = .{
                .sqfs = sqfs,
                .block = inode.internal.xtra.dir.start_block + sqfs.super_block.directory_table_start,
                .offset = inode.internal.xtra.dir.offset,
            },
            .offset = 0,
            .size = inode.internal.xtra.dir.size -| 3,
            .header = std.mem.zeroes(SquashFs.Dir.Header),
            .path = sqfs.allocator.alloc(u8, 0) catch unreachable,
        };
    }

    pub fn dataCache(
        sqfs: *SquashFs,
        cache: *Cache([]u8),
        pos: u64,
        header: Block.DataEntry,
    ) ![]u8 {
        const allocator = sqfs.allocator;

        var out_buf = cache.getDataBuf().?;
        const scratch_buf = cache.getCompressedDataBuf().?;

        return cache.get(pos) orelse blk: {
            const block_data = try blockReadIntoBuf(
                allocator,
                sqfs,
                pos,
                !header.is_uncompressed,
                header.size,
                &out_buf,
                scratch_buf,
            );

            cache.put(pos, block_data);

            break :blk block_data;
        };
    }

    pub fn mdCache(
        sqfs: *SquashFs,
        pos: *u64,
    ) !metadata.Block {
        var out_buf = sqfs.md_cache.getDataBuf().?;
        const scratch_buf = sqfs.md_cache.getCompressedDataBuf().?;

        const block: metadata.Block = sqfs.md_cache.get(pos.*) orelse blk: {
            var header: Block.MetadataEntry = undefined;

            try sqfs.load(
                &header,
                pos.* + sqfs.opts.offset,
            );

            header = littleToNative(header);

            const block_data = try blockReadIntoBuf(
                sqfs.md_cache.allocator,
                sqfs,
                pos.* + @sizeOf(Block.MetadataEntry),
                !header.is_uncompressed,
                header.size,
                &out_buf,
                scratch_buf,
            );

            const b = metadata.Block{
                .data_size = header.size + @sizeOf(Block.MetadataEntry),
                .data = block_data,
            };

            sqfs.md_cache.put(pos.*, b);

            break :blk b;
        };

        pos.* += block.data_size;

        return block;
    }

    pub const Inode = @import("fs/Inode.zig");
    pub const File = @import("fs/File.zig");
    pub const Dir = @import("fs/Dir.zig");
    pub const MetadataCursor = metadata.Cursor;

    pub fn mdSkip(
        sqfs: *SquashFs,
        cur: *metadata.Cursor,
        skip: usize,
    ) !void {
        var pos = cur.block;

        var size = skip;

        while (size > 0) {
            const block = try sqfs.mdCache(&pos);

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
        _: u32,
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
};

fn blockReadIntoBuf(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: u64,
    compressed: bool,
    size: u32,

    // Out buffer, it must not be freed while the block is active
    data: *[]u8,

    // Scratch buffer, this is filled with the compressed data, may be freed
    // after use
    scratch_buf: []u8,
) ![]u8 {
    var block_data = data.*;

    if (compressed) {
        try sqfs.load(
            scratch_buf[0..size],
            pos + sqfs.opts.offset,
        );

        const written = try sqfs.decompressFn(
            allocator,
            scratch_buf[0..size],
            block_data,
        );

        return block_data[0..written];
    }

    block_data = block_data[0..size];

    try sqfs.load(
        block_data,
        pos + sqfs.opts.offset,
    );

    return block_data;
}

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
