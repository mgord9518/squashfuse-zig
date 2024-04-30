const std = @import("std");
const os = std.os;
const squashfuse = @import("../root.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

sqfs: *SquashFs,
cur: SquashFs.MdCursor,
offset: u64,
total: u64,
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

const InternalEntry = packed struct {
    offset: u16,
    inode_number: u16,

    // InternalKind only needs a u4 but the datatype draws in 16 bits for it
    kind: InternalKind,
    UNUSED: u12,

    size: u16,

    pub const InternalKind = SquashFs.File.InternalKind;
};

pub const Header = extern struct {
    count: u32,
    start_block: u32,
    inode_number: u32,
};

// TODO: properly handle paths starting with `/`
//pub fn openDir(dir: *Dir, sub_path: []const u8, opts: std.fs.Dir.OpenDirOptions) std.fs.Dir.OpenError!Dir {
pub fn openDir(dir: *Dir, sub_path: []const u8, opts: std.fs.Dir.OpenDirOptions) !Dir {
    _ = opts;

    var arena = std.heap.ArenaAllocator.init(dir.sqfs.allocator);
    defer arena.deinit();

    var name_buf: [257]u8 = undefined;

    // Find the highest directory in the pathname
    var target = sub_path;
    var idx: usize = 0;
    while (std.fs.path.dirname(target)) |new_target| {
        target = new_target;
        idx += 1;
    }

    var iterator = Dir.Iterator{
        .name_buf = &name_buf,
        .sqfs = dir.sqfs,
        .allocator = arena.allocator(),
        .dir = dir,
    };

    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, target)) {
            if (idx == 0) {
                return dir.*;
            }

            const inode_number = entry.inode;
            var inode = try dir.sqfs.getInode(inode_number);
            var new_dir = try Dir.open(dir.sqfs, &inode);

            return new_dir.openDir(sub_path[target.len + 1 ..], .{});
        }
    }

    unreachable;
}

pub fn open(sqfs: *SquashFs, inode: *SquashFs.Inode) !Dir {
    if (inode.kind != .directory) return error.NotDir;

    return .{
        .sqfs = sqfs,
        .cur = .{
            .sqfs = sqfs,
            .block = @intCast(inode.internal.xtra.dir.start_block + sqfs.super_block.directory_table_start),
            .offset = inode.internal.xtra.dir.offset,
        },
        .offset = 0,
        .total = @intCast(inode.internal.xtra.dir.size -| 3),
        .header = std.mem.zeroes(Header),
    };
}

pub const Iterator = struct {
    sqfs: *SquashFs,
    name_buf: []u8,
    allocator: std.mem.Allocator,
    dir: *Dir,

    pub fn next(
        iterator: *Iterator,
    ) !?Dir.Entry {
        var ll_entry: InternalEntry = undefined;
        var entry: SquashFs.Dir.Entry = undefined;
        var dir = iterator.dir;

        entry.name = iterator.name_buf;

        entry.offset = dir.offset;

        while (dir.header.count == 0) {
            if (dir.offset >= dir.total) {
                return null;
            }

            const header_slice: []u8 = @as([*]u8, @ptrCast(&dir.header))[0..@sizeOf(@TypeOf(dir.header))];

            dir.offset += header_slice.len;
            try dir.cur.read(iterator.allocator, header_slice);

            dir.header = squashfuse.littleToNative(dir.header);
            dir.header.count += 1;
        }

        const e_slice: []u8 = @as([*]u8, @ptrCast(&ll_entry))[0..@sizeOf(@TypeOf(ll_entry))];
        try dirMdRead(iterator.allocator, iterator.sqfs, dir, e_slice);

        ll_entry = squashfuse.littleToNative(ll_entry);

        dir.header.count -= 1;

        entry.kind = ll_entry.kind.toKind();

        entry.name.len = ll_entry.size + 1;

        entry.inode = .{
            .block = dir.header.start_block,
            .offset = ll_entry.offset,
        };

        entry.inode_number = dir.header.inode_number + ll_entry.inode_number;

        try dirMdRead(iterator.allocator, iterator.sqfs, dir, entry.name);

        return entry;
    }
};

fn dirMdRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    dir: *SquashFs.Dir,
    buf: []u8,
) !void {
    _ = sqfs;
    dir.offset += @intCast(buf.len);

    try dir.cur.read(allocator, buf);
}
