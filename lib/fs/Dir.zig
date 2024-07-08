const std = @import("std");
const os = std.os;
const squashfuse = @import("../root.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

// Must be a string allocated by `sqfs.allocator`
path: ?[]const u8 = null,

sqfs: *SquashFs,
cur: SquashFs.MetadataCursor,
offset: u64,
size: u64,
header: Header,

pub const Entry = struct {
    kind: Kind,
    name: []u8,

    inode: SquashFs.Inode.TableEntry,
    inode_number: u32,
    offset: u64,
    next_offset: u64,

    pub const Kind = SquashFs.File.Kind;
};

const InternalEntry = packed struct(u64) {
    offset: u16,
    inode_number: u16,

    kind: InternalKind,
    _: u12,

    size: u16,

    pub const InternalKind = SquashFs.File.InternalKind;
};

pub const Header = extern struct {
    count: u32,
    start_block: u32,
    inode_number: u32,
};

fn populateInodeMapIfNull(sqfs: *SquashFs) !void {
    if (sqfs.inode_map == null) {
        sqfs.inode_map = std.StringHashMap(
            SquashFs.Inode.TableEntry,
        ).init(sqfs.allocator);

        var root_inode = sqfs.getRootInode();
        var walker = try root_inode.walk(sqfs.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            try sqfs.inode_map.?.put(
                try sqfs.allocator.dupe(u8, entry.path),
                entry.id,
            );
        }
    }
}

pub fn openDir(
    dir: *Dir,
    sub_path: []const u8,
    opts: std.fs.Dir.OpenDirOptions,
) !Dir {
    _ = opts;

    var sqfs = dir.sqfs;

    try populateInodeMapIfNull(sqfs);

    const resolved = try std.fs.path.resolve(
        sqfs.allocator,
        &.{ dir.path.?, sub_path },
    );

    const inode_entry = sqfs.inode_map.?.get(
        resolved,
    ) orelse unreachable;

    return Dir.initFromInodeTableEntry(
        sqfs,
        inode_entry,
        resolved,
    );
}

pub fn close(dir: *Dir) void {
    if (dir.path) |path| {
        dir.sqfs.allocator.free(path);
        dir.path = null;
    }
}

// Low-level init function for internal usage
pub fn initFromInodeTableEntry(
    sqfs: *SquashFs,
    table_entry: SquashFs.Inode.TableEntry,
    path: []const u8,
) !Dir {
    const inode = try sqfs.getInode(table_entry);

    if (inode.kind != .directory) return error.NotDir;

    const start_block = inode.internal.xtra.dir.start_block;

    return .{
        .sqfs = sqfs,
        .cur = .{
            .sqfs = sqfs,
            .block = sqfs.super_block.directory_table_start + start_block,
            .offset = inode.internal.xtra.dir.offset,
        },
        .offset = 0,
        .size = inode.internal.xtra.dir.size -| 3,
        .header = std.mem.zeroes(Header),
        .path = path,
    };
}

pub fn initFromInode(sqfs: *SquashFs, inode: *SquashFs.Inode) !Dir {
    if (inode.kind != .directory) return error.NotDir;

    return .{
        .sqfs = sqfs,
        .cur = .{
            .sqfs = sqfs,
            .block = @intCast(inode.internal.xtra.dir.start_block + sqfs.super_block.directory_table_start),
            .offset = inode.internal.xtra.dir.offset,
        },
        .offset = 0,
        .size = @intCast(inode.internal.xtra.dir.size -| 3),
        .header = std.mem.zeroes(Header),
    };
}

pub fn iterate(dir: *Dir) !Iterator {
    return Dir.Iterator{
        .name_buf = undefined,
        .sqfs = dir.sqfs,
        .dir = dir,
    };
}

pub const Iterator = struct {
    sqfs: *SquashFs,
    name_buf: [257]u8,
    dir: *Dir,

    pub fn next(
        iterator: *Iterator,
    ) !?Dir.Entry {
        var ll_entry: InternalEntry = undefined;
        var entry: SquashFs.Dir.Entry = undefined;
        var dir = iterator.dir;

        entry.name = &iterator.name_buf;

        entry.offset = dir.offset;

        while (dir.header.count == 0) {
            if (dir.offset >= dir.size) {
                return null;
            }

            dir.offset += @sizeOf(Header);
            try dir.cur.load(&dir.header);

            dir.header = squashfuse.littleToNative(dir.header);
            dir.header.count += 1;
        }

        dir.offset += @sizeOf(InternalEntry);
        try dir.cur.load(&ll_entry);

        ll_entry = squashfuse.littleToNative(ll_entry);

        dir.header.count -= 1;

        entry.kind = ll_entry.kind.toKind();

        entry.name.len = ll_entry.size + 1;

        entry.inode = .{
            .block = dir.header.start_block,
            .offset = ll_entry.offset,
        };

        entry.inode_number = dir.header.inode_number + ll_entry.inode_number;

        dir.offset += entry.name.len;
        try dir.cur.load(entry.name);

        return entry;
    }
};

pub const IteratorOld = struct {
    sqfs: *SquashFs,
    name_buf: []u8,
    dir: *Dir,

    pub fn next(
        iterator: *IteratorOld,
    ) !?Dir.Entry {
        var ll_entry: InternalEntry = undefined;
        var entry: SquashFs.Dir.Entry = undefined;
        var dir = iterator.dir;

        entry.name = iterator.name_buf;

        entry.offset = dir.offset;

        while (dir.header.count == 0) {
            if (dir.offset >= dir.size) {
                return null;
            }

            dir.offset += @sizeOf(Header);
            try dir.cur.load(&dir.header);

            dir.header = squashfuse.littleToNative(dir.header);
            dir.header.count += 1;
        }

        dir.offset += @sizeOf(InternalEntry);
        try dir.cur.load(&ll_entry);

        ll_entry = squashfuse.littleToNative(ll_entry);

        dir.header.count -= 1;

        entry.kind = ll_entry.kind.toKind();

        entry.name.len = ll_entry.size + 1;

        entry.inode = .{
            .block = dir.header.start_block,
            .offset = ll_entry.offset,
        };

        entry.inode_number = dir.header.inode_number + ll_entry.inode_number;

        dir.offset += entry.name.len;
        try dir.cur.load(entry.name);

        return entry;
    }
};
